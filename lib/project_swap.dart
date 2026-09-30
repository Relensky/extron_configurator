import 'dart:convert';
import 'dart:io';

import 'app_logger.dart';
import 'app_state.dart' show activeDeviceKeysIn;
import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'building_project.dart';
import 'model_swap.dart';
import 'project_estimate.dart';
import 'safe_write.dart';

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

  /// What each swapped box would be named afterwards, with no name given.
  final List<String> labels;

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
    this.labels = const [],
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

  /// Every distinct name the swapped boxes would carry afterwards.
  List<String> get labels => {
        for (final r in affectedRooms) ...r.labels,
      }.toList();
}

/// Works out what swapping [fromModel] to [template] would do to every room on
/// the project. Nothing is written.
///
/// Only each room's config and drawing are read, in the background and a few
/// rooms at a time; [onProgress] hears rooms done against the total.
///
/// [openConfigPath] is the room currently in the editor, so its row can be
/// marked and its files left alone — pass '' when no room is open.
Future<ProjectSwapPlan> planProjectSwap({
  required BuildingProject project,
  required String projectPath,
  required String fromModel,
  required AvDeviceTemplate template,
  required String Function(String model) moduleForModel,
  required Map<String, String> deviceCountMap,
  String openConfigPath = '',
  void Function(int done, int total)? onProgress,
}) async {
  final needle = fromModel.trim().toLowerCase();

  final plans = await _pooled(project.rooms, (ref) async {
    final absolute = BuildingProject.resolvePath(ref.configPath, projectPath);
    final files = await _readRoomFiles(absolute);
    final name = _roomName(ref, files.config);

    if (files.error.isNotEmpty) {
      return RoomSwapPlan(
        ref: ref,
        roomName: name,
        configPath: absolute,
        error: files.error,
      );
    }

    final matches = [
      for (final raw in _boxesOn(files.flow, needle))
        AvNode.fromJson(Map<String, dynamic>.from(raw)),
    ];
    if (matches.isEmpty) {
      return RoomSwapPlan(ref: ref, roomName: name, configPath: absolute);
    }
    final cables = _cablesOn(files.flow, {for (final n in matches) n.id});

    var carried = 0;
    var dropped = 0;
    var heightChanged = false;
    final labels = <String>[];
    // Each box is planned against the cables as they stand, then the results
    // are added up. Two boxes of the same model in one room cannot both claim
    // the same run — a cable has one end on each — so there is no double
    // counting to guard against here.
    for (final node in matches) {
      final plan = planModelSwap(
        node: node,
        cables: cables,
        template: template,
        config: files.config,
      );
      carried += plan.carried;
      dropped += plan.dropped.length;
      if (plan.rackHeightChanged(node)) heightChanged = true;
      labels.add(plan.node.label);
    }

    // Which of those boxes have a control block behind them. Only live device
    // sections count: a stale DISPLAYDEVICE_4 in a room whose count says three
    // is not part of the room and must not be rewritten.
    final live = activeDeviceKeysIn(files.config, deviceCountMap).toSet();
    final blocks = matches
        .where((n) => live.contains(n.id) && files.config[n.id] is Map)
        .length;

    return RoomSwapPlan(
      ref: ref,
      roomName: name,
      configPath: absolute,
      nodeIds: [for (final n in matches) n.id],
      carried: carried,
      dropped: dropped,
      blocks: blocks,
      rackHeightChanged: heightChanged,
      labels: labels,
      isOpenRoom: openConfigPath.isNotEmpty &&
          _samePath(openConfigPath, absolute),
    );
  }, onProgress: onProgress);

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

/// Applies [plan] to every affected room's files, a few rooms at a time.
///
/// The room marked [RoomSwapPlan.isOpenRoom] is SKIPPED — the caller applies
/// that one through the provider so the editor and the disk cannot disagree.
///
/// A room that fails to write is reported and the rest still go: a share that
/// dropped out halfway through a nine-room swap should leave eight rooms done
/// and one named, not nine rooms in an unknown state.
///
/// A non-empty [label] names every swapped box, and its control block, that.
Future<ProjectSwapResult> applyProjectSwap({
  required ProjectSwapPlan plan,
  required String Function(String model) moduleForModel,
  required Map<String, String> deviceCountMap,
  String label = '',
  void Function(int done, int total)? onProgress,
}) async {
  final todo = [
    for (final r in plan.affectedRooms)
      if (!r.isOpenRoom) r,
  ];

  final results = await _pooled(todo, (room) async {
    try {
      final done = await _swapInRoomFiles(
        room: room,
        template: plan.to,
        fromModel: plan.fromModel,
        moduleForModel: moduleForModel,
        deviceCountMap: deviceCountMap,
        label: label,
      );
      AppLogger.logInfo(
        'Project swap: ${room.roomName} - ${done.boxes} box(es) moved from '
        '"${plan.fromModel}" to "${plan.to.model}", ${done.carried} run(s) '
        'carried, ${done.dropped} dropped, ${done.blocks} control block(s) '
        'updated.',
      );
      return (done: done, error: '');
    } catch (e, stack) {
      AppLogger.logError(
        'Project swap could not write ${room.configPath}',
        e,
        stack,
      );
      return (
        done: (boxes: 0, carried: 0, dropped: 0, blocks: 0),
        error: '${room.roomName} - $e',
      );
    }
  }, onProgress: onProgress);

  final ok = [for (final r in results) if (r.error.isEmpty) r.done];
  return (
    rooms: ok.length,
    boxes: ok.fold(0, (s, d) => s + d.boxes),
    carried: ok.fold(0, (s, d) => s + d.carried),
    dropped: ok.fold(0, (s, d) => s + d.dropped),
    blocks: ok.fold(0, (s, d) => s + d.blocks),
    failures: [
      for (final r in results)
        if (r.error.isNotEmpty) r.error,
    ],
  );
}

// ---------------------------------------------------------------------------
//  WRITING ONE ROOM
// ---------------------------------------------------------------------------

const JsonEncoder _encoder = JsonEncoder.withIndent('    ');

/// Rewrites one room's diagram file and config in place.
///
/// Re-reads rather than trusting the plan's copy: the plan may have been built
/// against a read minutes ago, and a room edited in between must not be
/// written back from a stale picture. The read here is the one that counts.
///
/// The drawing is edited as the JSON it is: the swapped boxes and the runs on
/// them are replaced, everything else in the file is written back as found.
Future<({int boxes, int carried, int dropped, int blocks})> _swapInRoomFiles({
  required RoomSwapPlan room,
  required AvDeviceTemplate template,
  required String fromModel,
  required String Function(String model) moduleForModel,
  required Map<String, String> deviceCountMap,
  String label = '',
}) async {
  final files = await _readRoomFiles(room.configPath);
  if (files.error.isNotEmpty) throw StateError(files.error);
  final flow = files.flow;
  // No diagram file: nothing on the drawing to swap. Not an error — a room
  // can be config-only — but there is also nothing to do.
  if (flow == null) return (boxes: 0, carried: 0, dropped: 0, blocks: 0);

  final needle = fromModel.trim().toLowerCase();
  final matches = [
    for (final raw in _boxesOn(flow, needle))
      AvNode.fromJson(Map<String, dynamic>.from(raw)),
  ];
  if (matches.isEmpty) return (boxes: 0, carried: 0, dropped: 0, blocks: 0);

  // --- the drawing ---------------------------------------------------------
  final swapped = <String, AvNode>{};
  final cablesById = {
    for (final c in _cablesOn(flow, {for (final n in matches) n.id})) c.id: c,
  };
  final moved = <String, AvCable>{};
  final removed = <String>{};

  for (final node in matches) {
    final plan = planModelSwap(
      node: node,
      cables: cablesById.values,
      template: template,
      config: files.config,
      label: label,
    );
    swapped[node.id] = plan.node;
    for (final entry in plan.moved.entries) {
      cablesById[entry.key] = entry.value;
      moved[entry.key] = entry.value;
    }
    removed.addAll(plan.dropped);
  }

  // The diagram's own order, so a rewritten file is a diff somebody can read.
  flow['nodes'] = [
    for (final n in (flow['nodes'] as List? ?? const []))
      if (n is Map && swapped.containsKey(n['id']))
        swapped[n['id']]!.toJson()
      else
        n,
  ];
  flow['cables'] = [
    for (final c in (flow['cables'] as List? ?? const []))
      if (c is Map && removed.contains(c['id']))
        ...const []
      else if (c is Map && moved.containsKey(c['id']))
        moved[c['id']]!.toJson()
      else
        c,
  ];
  await writeFileSafely(files.flowPath, _encoder.convert(flow));

  // --- the control side ----------------------------------------------------
  final live = activeDeviceKeysIn(files.config, deviceCountMap).toSet();
  var blocks = 0;
  for (final node in matches) {
    if (!live.contains(node.id)) continue;
    final block = files.config[node.id];
    if (block is! Map) continue;
    swapControlBlock(block, template.model, moduleForModel, name: label);
    blocks++;
  }
  if (blocks > 0) {
    await writeFileSafely(room.configPath, _encoder.convert(files.config));
  }

  return (
    boxes: matches.length,
    carried: moved.length,
    dropped: removed.length,
    blocks: blocks,
  );
}

// ---------------------------------------------------------------------------
//  READING A ROOM FOR A PROJECT-WIDE EDIT
// ---------------------------------------------------------------------------
//  Only the config and the drawing are read - a swap or a rename touches
//  nothing else - in the background and a few rooms at a time, so a
//  thirty-room job on the share neither freezes the window nor waits on one
//  room after another.

/// How many rooms are read or written at once.
const int _poolWidth = 4;

/// The two files a project-wide edit touches, as read.
typedef _RoomFiles = ({
  Map<String, dynamic> config,
  String flowPath,
  Map<String, dynamic>? flow,
  String error,
});

Future<_RoomFiles> _readRoomFiles(String configPath) async {
  _RoomFiles failed(String why) =>
      (config: const {}, flowPath: '', flow: null, error: why);
  final Map<String, dynamic> config;
  try {
    final file = File(configPath);
    if (!await file.exists()) return failed('The config is not at $configPath.');
    final doc = jsonDecode(await file.readAsString());
    if (doc is! Map) return failed('The config could not be read.');
    config = Map<String, dynamic>.from(doc);
  } catch (e) {
    return failed('The config could not be read: $e');
  }
  for (final path in roomFlowCandidates(configPath)) {
    try {
      final file = File(path);
      if (!await file.exists()) continue;
      final doc = jsonDecode(await file.readAsString());
      if (doc is! Map) continue;
      return (
        config: config,
        flowPath: path,
        flow: Map<String, dynamic>.from(doc),
        error: '',
      );
    } catch (e) {
      AppLogger.logError('Project edit could not read $path', e);
    }
  }
  return (config: config, flowPath: '', flow: null, error: '');
}

/// What the project calls a room: its label, else the config's title.
String _roomName(ProjectRoomRef ref, Map<String, dynamic> config) {
  final setup = config['SYSTEM_SETUP'];
  final title =
      (setup is Map ? setup['gui_full_room_name']?.toString() : null)?.trim() ??
          '';
  return ref.label.trim().isNotEmpty
      ? ref.label.trim()
      : title.isNotEmpty
          ? title
          : ref.fallbackName;
}

/// The drawing's boxes on [needle] (a lower-cased model), as their JSON.
List<Map> _boxesOn(Map<String, dynamic>? flow, String needle) => [
      for (final n in (flow?['nodes'] as List? ?? const []))
        if (n is Map &&
            (n['id']?.toString() ?? '').isNotEmpty &&
            (n['model']?.toString() ?? '').trim().toLowerCase() == needle)
          n,
    ];

/// The drawing's runs with an end on one of [nodeIds].
List<AvCable> _cablesOn(Map<String, dynamic>? flow, Set<String> nodeIds) => [
      for (final c in (flow?['cables'] as List? ?? const []))
        if (c is Map &&
            (c['id']?.toString() ?? '').isNotEmpty &&
            (nodeIds.contains(c['fromNode']) ||
                nodeIds.contains(c['toNode'])))
          AvCable.fromJson(Map<String, dynamic>.from(c)),
    ];

/// [work] over [items], [_poolWidth] at a time, results in [items]' order.
Future<List<R>> _pooled<T, R>(
  List<T> items,
  Future<R> Function(T item) work, {
  void Function(int done, int total)? onProgress,
}) async {
  final out = List<R?>.filled(items.length, null);
  var next = 0;
  var done = 0;
  onProgress?.call(0, items.length);
  Future<void> lane() async {
    while (next < items.length) {
      final i = next++;
      out[i] = await work(items[i]);
      onProgress?.call(++done, items.length);
    }
  }

  await Future.wait([
    for (var i = 0; i < _poolWidth && i < items.length; i++) lane(),
  ]);
  return out.cast<R>();
}

// ---------------------------------------------------------------------------
//  RENAMING WITHOUT SWAPPING
// ---------------------------------------------------------------------------
//  Read as the swap reads - see [_readRoomFiles] - and the boxes edited as
//  the JSON they are, so nothing but the label moves.

/// Every room that has a box on [model], with its current names in
/// [RoomSwapPlan.labels]. Nothing is written; the model is not touched.
///
/// Unreadable rooms are kept on the list, as for a swap.
Future<List<RoomSwapPlan>> planProjectRename({
  required BuildingProject project,
  required String projectPath,
  required String model,
  required Map<String, String> deviceCountMap,
  String openConfigPath = '',
  void Function(int done, int total)? onProgress,
}) {
  final needle = model.trim().toLowerCase();
  return _pooled(project.rooms, (ref) async {
    final absolute = BuildingProject.resolvePath(ref.configPath, projectPath);
    final files = await _readRoomFiles(absolute);
    final name = _roomName(ref, files.config);
    if (files.error.isNotEmpty) {
      return RoomSwapPlan(
        ref: ref,
        roomName: name,
        configPath: absolute,
        error: files.error,
      );
    }

    final boxes = _boxesOn(files.flow, needle);
    final ids = [for (final n in boxes) n['id'].toString()];
    final live = activeDeviceKeysIn(files.config, deviceCountMap).toSet();
    return RoomSwapPlan(
      ref: ref,
      roomName: name,
      configPath: absolute,
      nodeIds: ids,
      blocks: ids
          .where((id) => live.contains(id) && files.config[id] is Map)
          .length,
      labels: [for (final n in boxes) n['label']?.toString() ?? ''],
      isOpenRoom: openConfigPath.isNotEmpty &&
          _samePath(openConfigPath, absolute),
    );
  }, onProgress: onProgress);
}

/// Names every box on [model], and its control block, [label] in each of
/// [rooms]' files. The open room is skipped, as for a swap. A file is only
/// written when something in it changes.
Future<ProjectSwapResult> applyProjectRename({
  required List<RoomSwapPlan> rooms,
  required String model,
  required String label,
  required Map<String, String> deviceCountMap,
  void Function(int done, int total)? onProgress,
}) async {
  final needle = model.trim().toLowerCase();
  final name = label.trim();
  final todo = [
    for (final r in rooms)
      if (r.affected && !r.isOpenRoom && name.isNotEmpty) r,
  ];

  final results = await _pooled(todo, (room) async {
    try {
      // Re-read, as the swap does: the plan may be stale.
      final files = await _readRoomFiles(room.configPath);
      if (files.error.isNotEmpty) throw StateError(files.error);
      final boxes = _boxesOn(files.flow, needle);
      if (boxes.isEmpty) return (boxes: 0, blocks: 0, error: '');

      if (boxes.any((n) => n['label'] != name)) {
        for (final n in boxes) {
          n['label'] = name;
        }
        await writeFileSafely(files.flowPath, _encoder.convert(files.flow));
      }

      final live = activeDeviceKeysIn(files.config, deviceCountMap).toSet();
      var blocks = 0;
      var configChanged = false;
      for (final n in boxes) {
        final id = n['id'].toString();
        final block = files.config[id];
        if (!live.contains(id) || block is! Map) continue;
        blocks++;
        if (block['name'] == name) continue;
        block['name'] = name;
        configChanged = true;
      }
      if (configChanged) {
        await writeFileSafely(room.configPath, _encoder.convert(files.config));
      }

      AppLogger.logInfo(
        'Project rename: ${room.roomName} - ${boxes.length} "$model" '
        'box(es) named "$name".',
      );
      return (boxes: boxes.length, blocks: blocks, error: '');
    } catch (e, stack) {
      AppLogger.logError(
        'Project rename could not write ${room.configPath}',
        e,
        stack,
      );
      return (boxes: 0, blocks: 0, error: '${room.roomName} - $e');
    }
  }, onProgress: onProgress);

  return (
    rooms: results.where((r) => r.error.isEmpty && r.boxes > 0).length,
    boxes: results.fold(0, (s, r) => s + r.boxes),
    carried: 0,
    dropped: 0,
    blocks: results.fold(0, (s, r) => s + r.blocks),
    failures: [
      for (final r in results)
        if (r.error.isNotEmpty) r.error,
    ],
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
