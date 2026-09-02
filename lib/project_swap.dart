import 'dart:convert';
import 'dart:io';

import 'app_logger.dart';
import 'app_state.dart' show activeDeviceKeysIn;
import 'av_device_library.dart';
import 'building_project.dart';
import 'model_swap.dart';
import 'project_estimate.dart';

/// ============================================================================
///  SWAPPING A PRODUCT ACROSS A WHOLE BUILDING
/// ============================================================================
///  The projector everybody specified is discontinued. Nine rooms have one.
///  Before this, that was nine rooms opened in turn, nine swaps, nine saves —
///  and the ninth one done a week later by somebody else, on a different model,
///  because the decision was never written down anywhere.
///
///  This does the same swap the room does, in every room at once, from the
///  core components list where the problem is actually visible.
///
///  THREE THINGS MAKE IT SAFE ENOUGH TO DO AT ALL:
///
///  1. IT IS PLANNED BEFORE IT IS APPLIED. [planProjectSwap] reads every room
///     and works out exactly what would change — how many boxes, which runs
///     carry, which get dropped, which control blocks lose their module — and
///     writes nothing. The dialog shows that; only then is anything written.
///
///  2. THE WRITE IS SURGICAL. It does not load a room through the app's
///     opener and save it back, which would re-run every migration, every
///     auto-fill and every default-filler on a file nobody asked to touch. It
///     reads the room's own JSON, replaces the `nodes` and `cables` keys and
///     the device blocks that changed, and writes the rest back exactly as it
///     was found — including into the pre-rename sidecar name, if that is what
///     the room has. A swap has no business reorganizing somebody's folder.
///
///  3. THE OPEN ROOM IS NEVER WRITTEN BEHIND THE APP'S BACK. If the room in
///     the editor is on the project, writing its files would put the swap on
///     disk and the old model in memory, and the next Save would silently undo
///     it. So it is skipped here and applied through the provider instead —
///     where it lands as one undo entry, like any other swap.
///
///  The arithmetic is model_swap.dart, shared with the single-room swap, so a
///  box swapped from here and a box swapped on the Signal Flow tab cannot come
///  out differently.
/// ============================================================================

/// What the swap would do — or did — to one room.
class RoomSwapPlan {
  final ProjectRoomRef ref;
  final String roomName;

  /// Absolute path to the room's config.
  final String configPath;

  /// Ids of the boxes on the diagram being swapped.
  final List<String> nodeIds;

  /// Runs moved onto the new product's matching connectors.
  final int carried;

  /// Runs whose connector has no counterpart on the new product. These are
  /// removed — see [ModelSwapPlan.dropped] — and this is the number the
  /// confirm dialog leads with, because it is the only genuinely destructive
  /// part of a swap.
  final int dropped;

  /// Config device blocks that follow the box.
  final int blocks;

  /// True when the new product is a different rack height, so somebody has to
  /// look at the elevation. The slot is kept either way.
  final bool rackHeightChanged;

  /// Why this room could not be read — '' when it was fine.
  final String error;

  /// True when this is the room currently open in the editor, which is applied
  /// in memory rather than written.
  final bool isOpenRoom;

  const RoomSwapPlan({
    required this.ref,
    required this.roomName,
    required this.configPath,
    this.nodeIds = const [],
    this.carried = 0,
    this.dropped = 0,
    this.blocks = 0,
    this.rackHeightChanged = false,
    this.error = '',
    this.isOpenRoom = false,
  });

  bool get ok => error.isEmpty;
  int get boxes => nodeIds.length;

  /// True when there is something to do here. A room on the project that
  /// simply does not have this product is not a problem and not a change; it
  /// is left off the dialog entirely.
  bool get affected => boxes > 0;
}

/// The whole swap, across the building.
class ProjectSwapPlan {
  /// The model being replaced, as it is spelled on the diagrams.
  final String fromModel;

  /// The catalog entry replacing it.
  final AvDeviceTemplate to;

  /// Every room that has the old product, plus every room that could not be
  /// read — a swap that silently skipped an unreadable room would leave one
  /// room on the old product with nothing saying so.
  final List<RoomSwapPlan> rooms;

  /// The python module claiming the new model, or '' when nothing does.
  ///
  /// '' is not a refusal — specifying a device before its driver exists is
  /// ordinary — but it IS the thing the dialog says out loud, because every
  /// control block in the swap will have its module cleared and every one of
  /// those devices lands on the "no control module" list afterwards.
  final String newModule;

  const ProjectSwapPlan({
    required this.fromModel,
    required this.to,
    required this.rooms,
    required this.newModule,
  });

  List<RoomSwapPlan> get affectedRooms =>
      [for (final r in rooms) if (r.affected) r];

  List<RoomSwapPlan> get failedRooms => [for (final r in rooms) if (!r.ok) r];

  int get boxes => affectedRooms.fold(0, (s, r) => s + r.boxes);
  int get carried => affectedRooms.fold(0, (s, r) => s + r.carried);
  int get dropped => affectedRooms.fold(0, (s, r) => s + r.dropped);
  int get blocks => affectedRooms.fold(0, (s, r) => s + r.blocks);

  bool get isEmpty => affectedRooms.isEmpty;
  bool get losesModule => newModule.isEmpty && blocks > 0;
  bool get anyRackHeightChanged =>
      affectedRooms.any((r) => r.rackHeightChanged);
}

/// Works out what swapping [fromModel] to [template] would do to every room on
/// the project. Nothing is written.
///
/// [openConfigPath] is the room currently in the editor, so its row can be
/// marked and its files left alone — pass '' when no room is open.
ProjectSwapPlan planProjectSwap({
  required BuildingProject project,
  required String projectPath,
  required String fromModel,
  required AvDeviceTemplate template,
  required String Function(String model) moduleForModel,
  required Map<String, String> deviceCountMap,
  String openConfigPath = '',
  Map<String, LoadedRoom>? rooms,
}) {
  final needle = fromModel.trim().toLowerCase();
  final plans = <RoomSwapPlan>[];

  for (final ref in project.rooms) {
    final absolute = BuildingProject.resolvePath(ref.configPath, projectPath);
    final room = rooms?[ref.id] ?? readRoomFromDisk(absolute);
    final name = ref.label.trim().isNotEmpty
        ? ref.label.trim()
        : room.title.trim().isNotEmpty
            ? room.title.trim()
            : ref.fallbackName;

    if (!room.ok) {
      plans.add(RoomSwapPlan(
        ref: ref,
        roomName: name,
        configPath: absolute,
        error: room.error,
      ));
      continue;
    }

    final matches = [
      for (final n in room.model.nodes)
        if (n.model.trim().toLowerCase() == needle) n,
    ];
    if (matches.isEmpty) {
      plans.add(
        RoomSwapPlan(ref: ref, roomName: name, configPath: absolute),
      );
      continue;
    }

    var carried = 0;
    var dropped = 0;
    var heightChanged = false;
    // Each box is planned against the cables as they stand, then the results
    // are added up. Two boxes of the same model in one room cannot both claim
    // the same run — a cable has one end on each — so there is no double
    // counting to guard against here.
    for (final node in matches) {
      final plan = planModelSwap(
        node: node,
        cables: room.model.cables,
        template: template,
        config: room.config,
      );
      carried += plan.carried;
      dropped += plan.dropped.length;
      if (plan.rackHeightChanged(node)) heightChanged = true;
    }

    // Which of those boxes have a control block behind them. Only live device
    // sections count: a stale DISPLAYDEVICE_4 in a room whose count says three
    // is not part of the room and must not be rewritten.
    final live = activeDeviceKeysIn(room.config, deviceCountMap).toSet();
    final blocks = matches
        .where((n) => live.contains(n.id) && room.config[n.id] is Map)
        .length;

    plans.add(RoomSwapPlan(
      ref: ref,
      roomName: name,
      configPath: absolute,
      nodeIds: [for (final n in matches) n.id],
      carried: carried,
      dropped: dropped,
      blocks: blocks,
      rackHeightChanged: heightChanged,
      isOpenRoom: openConfigPath.isNotEmpty &&
          _samePath(openConfigPath, absolute),
    ));
  }

  return ProjectSwapPlan(
    fromModel: fromModel,
    to: template,
    rooms: plans,
    newModule: moduleForModel(template.model),
  );
}

/// What actually happened when a plan was applied.
typedef ProjectSwapResult = ({
  int rooms,
  int boxes,
  int carried,
  int dropped,
  int blocks,
  List<String> failures,
});

/// Applies [plan] to every affected room's files.
///
/// The room marked [RoomSwapPlan.isOpenRoom] is SKIPPED — the caller applies
/// that one through the provider so the editor and the disk cannot disagree.
///
/// A room that fails to write is reported and the rest still go: a share that
/// dropped out halfway through a nine-room swap should leave eight rooms done
/// and one named, not nine rooms in an unknown state.
ProjectSwapResult applyProjectSwap({
  required ProjectSwapPlan plan,
  required String Function(String model) moduleForModel,
  required Map<String, String> deviceCountMap,
}) {
  var rooms = 0;
  var boxes = 0;
  var carried = 0;
  var dropped = 0;
  var blocks = 0;
  final failures = <String>[];

  for (final room in plan.affectedRooms) {
    if (room.isOpenRoom) continue;
    try {
      final done = _swapInRoomFiles(
        room: room,
        template: plan.to,
        fromModel: plan.fromModel,
        moduleForModel: moduleForModel,
        deviceCountMap: deviceCountMap,
      );
      rooms++;
      boxes += done.boxes;
      carried += done.carried;
      dropped += done.dropped;
      blocks += done.blocks;
      AppLogger.logInfo(
        'Project swap: ${room.roomName} - ${done.boxes} box(es) moved from '
        '"${plan.fromModel}" to "${plan.to.model}", ${done.carried} run(s) '
        'carried, ${done.dropped} dropped, ${done.blocks} control block(s) '
        'updated.',
      );
    } catch (e, stack) {
      AppLogger.logError(
        'Project swap could not write ${room.configPath}',
        e,
        stack,
      );
      failures.add('${room.roomName} - $e');
    }
  }

  return (
    rooms: rooms,
    boxes: boxes,
    carried: carried,
    dropped: dropped,
    blocks: blocks,
    failures: failures,
  );
}

// ---------------------------------------------------------------------------
//  WRITING ONE ROOM
// ---------------------------------------------------------------------------

const JsonEncoder _encoder = JsonEncoder.withIndent('    ');

/// Rewrites one room's diagram file and config in place.
///
/// Re-reads rather than trusting the plan's copy: the plan may have been built
/// against a cached read minutes ago, and a room edited in between must not be
/// written back from a stale picture. The read here is the one that counts.
({int boxes, int carried, int dropped, int blocks}) _swapInRoomFiles({
  required RoomSwapPlan room,
  required AvDeviceTemplate template,
  required String fromModel,
  required String Function(String model) moduleForModel,
  required Map<String, String> deviceCountMap,
}) {
  final loaded = readRoomFromDisk(room.configPath);
  if (!loaded.ok) throw StateError(loaded.error);
  if (loaded.flowPath.isEmpty) {
    // No diagram file: nothing on the drawing to swap. Not an error — a room
    // can be config-only — but there is also nothing to do.
    return (boxes: 0, carried: 0, dropped: 0, blocks: 0);
  }

  final needle = fromModel.trim().toLowerCase();
  final matches = [
    for (final n in loaded.model.nodes)
      if (n.model.trim().toLowerCase() == needle) n,
  ];
  if (matches.isEmpty) {
    return (boxes: 0, carried: 0, dropped: 0, blocks: 0);
  }

  // --- the drawing ---------------------------------------------------------
  final nodesById = {for (final n in loaded.model.nodes) n.id: n};
  final cablesById = {for (final c in loaded.model.cables) c.id: c};
  final removed = <String>{};
  var carried = 0;

  for (final node in matches) {
    final plan = planModelSwap(
      node: node,
      cables: cablesById.values,
      template: template,
      config: loaded.config,
    );
    nodesById[node.id] = plan.node;
    for (final entry in plan.moved.entries) {
      cablesById[entry.key] = entry.value;
      carried++;
    }
    removed.addAll(plan.dropped);
  }
  for (final id in removed) {
    cablesById.remove(id);
  }

  // The flow file as it sits on disk, with only the two keys the swap owns
  // replaced. Everything else in it — the colors, the room mode, the
  // backdrop, and on a pre-split room the racks and plans and estimate too —
  // is written back byte-identical.
  final flowFile = File(loaded.flowPath);
  final flowDoc = Map<String, dynamic>.from(
    jsonDecode(flowFile.readAsStringSync()) as Map,
  );
  flowDoc['nodes'] = [
    // The diagram's own order, not the map's: a rewritten file whose boxes
    // come back shuffled is a diff nobody can read.
    for (final n in loaded.model.nodes) nodesById[n.id]!.toJson(),
  ];
  flowDoc['cables'] = [
    for (final c in loaded.model.cables)
      if (cablesById.containsKey(c.id)) cablesById[c.id]!.toJson(),
  ];
  flowFile.writeAsStringSync(_encoder.convert(flowDoc));

  // --- the control side ----------------------------------------------------
  final live = activeDeviceKeysIn(loaded.config, deviceCountMap).toSet();
  var blocks = 0;
  for (final node in matches) {
    if (!live.contains(node.id)) continue;
    final block = loaded.config[node.id];
    if (block is! Map) continue;
    swapControlBlock(block, template.model, moduleForModel);
    blocks++;
  }
  if (blocks > 0) {
    File(room.configPath).writeAsStringSync(_encoder.convert(loaded.config));
  }

  return (
    boxes: matches.length,
    carried: carried,
    dropped: removed.length,
    blocks: blocks,
  );
}

/// Two paths naming the same file, allowing for Windows' case-insensitivity
/// and for one of them being spelled with different separators.
bool _samePath(String a, String b) {
  final left = a.replaceAll('\\', '/');
  final right = b.replaceAll('\\', '/');
  return Platform.isWindows
      ? left.toLowerCase() == right.toLowerCase()
      : left == right;
}
