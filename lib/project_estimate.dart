import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'base_costs.dart';
import 'building_project.dart';
import 'control_gaps.dart';
import 'cost_estimate.dart';
import 'labor_rates.dart';
import 'room_sidecar.dart';

/// ============================================================================
///  PRICING A BUILDING
/// ============================================================================
///  Turns a [BuildingProject] — a list of room config paths — into the three
///  documents a job actually needs:
///
///    * WHAT EACH ROOM COSTS, so the building total can be broken back down to
///      the room somebody is asking about.
///    * ONE CORE COMPONENTS LIST, with every room's quantities merged onto a
///      single line per part. This is the whole reason the feature exists: a
///      vendor asked to quote eighteen switchers as one line quotes better than
///      one asked to quote nine rooms of two.
///    * A PACKAGE PER VENDOR, so each of those lists can go out to the company
///      that actually sells the parts on it.
///
///  ROOMS ARE READ OFF DISK, NOT OPENED. Each room is a config plus its
///  sidecars, and [computeRoomCost] is a pure function of the diagram and the
///  estimate settings — so a room can be priced without the app loading it,
///  switching tabs to it, or disturbing the room the user has open. Nine rooms
///  cost nine file reads.
///
///  What that buys is more than speed. The alternative — walking the app's
///  loader across nine rooms — would fire every "this room has unsaved work"
///  prompt, every migration, every auto-fill, and would leave whichever room
///  happened to be last sitting in the editor. Reading is a read.
///
///  THE ROLLUP IS NOT A SUM OF GRAND TOTALS. Fees and tax are percentages, and
///  a percentage of a sum is not the sum of the percentages once rooms carry
///  different rates — so the building total adds each room's own grand total,
///  computed under that room's own fees and tax, and reports the components
///  alongside rather than re-deriving them. A building where two rooms are
///  taxed differently is a real thing, and it must not quietly average.
/// ============================================================================

// ---------------------------------------------------------------------------
//  READING A ROOM WITHOUT OPENING IT
// ---------------------------------------------------------------------------

/// One room, read off disk and ready to price.
class LoadedRoom {
  /// The config that was read.
  final String configPath;

  /// The room's name, off `SYSTEM_SETUP.gui_full_room_name`.
  final String title;

  /// The config itself, as read. Kept rather than discarded after the title is
  /// pulled out of it, because two things need it: the control-module rule
  /// (which device blocks exist, and which have a driver) and the swap (which
  /// blocks have to follow the box on the drawing).
  final Map<String, dynamic> config;

  /// The file the diagram was actually read from — the current
  /// `<config>_av_flow.json`, or the pre-rename `<config>_avflow.json` when
  /// that is what is on disk. '' when the room has no diagram file at all.
  ///
  /// Recorded so a write goes back to the file it came from. A swap has no
  /// business quietly renaming somebody's sidecar on its way past; the file
  /// moves when they save the room, which is where that decision belongs.
  final String flowPath;

  /// Enough of the diagram to cost it — see [readRoomFromDisk] for exactly
  /// how much, and why that is the right amount.
  final AvFlowModel model;

  final RoomCostSettings settings;

  /// Why this room could not be read, or '' when it was.
  ///
  /// A missing room does NOT throw. A building is quoted from a folder of
  /// files somebody is still working on: one room renamed, one not yet
  /// created, one on a share that is briefly offline. Nine rooms must not
  /// become no answer because of one, so the failure is carried on the room
  /// it belongs to and the other eight still price.
  final String error;

  const LoadedRoom({
    required this.configPath,
    required this.title,
    required this.model,
    required this.settings,
    this.config = const {},
    this.flowPath = '',
    this.error = '',
  });

  bool get ok => error.isEmpty;

  /// True when the room read fine but has nothing on it — a config saved
  /// before anybody drew the AV side. Distinct from an error, and the report
  /// says so: "not drawn yet" is a schedule fact, "file missing" is a problem.
  bool get isEmpty =>
      ok && model.nodes.isEmpty && model.rackItems.isEmpty &&
      settings.items.isEmpty &&
      settings.extraEquipment.isEmpty &&
      settings.extraHardware.isEmpty &&
      settings.extraCables.isEmpty &&
      settings.labor.isEmpty;
}

/// Reads a room's config and sidecars into the smallest model that prices it.
///
/// ONLY WHAT COSTING READS is built: the devices, the cables between them, and
/// the hardware placed in the racks. Not the floor plans (which reference
/// image files that may not travel with a project), not the locations, not the
/// cabling drawing's overrides — none of those touch a single figure on an
/// estimate, and reading them would mean a project rollup could fail on a
/// missing PNG. If costing ever grows to read one of them, it is added here
/// and the doc comment stops being true, which is the point of saying it.
LoadedRoom readRoomFromDisk(String configPath) {
  LoadedRoom failed(String why) => LoadedRoom(
    configPath: configPath,
    title: '',
    model: const AvFlowModel(
      nodes: [],
      cables: [],
      racks: [],
      rackSlots: {},
      canvasSize: Size(0, 0),
      roomTitle: '',
      unplaced: [],
    ),
    settings: RoomCostSettings(),
    error: why,
  );

  if (configPath.isEmpty) return failed('No file chosen for this room.');
  final configFile = File(configPath);
  if (!configFile.existsSync()) {
    return failed('The config is not at $configPath.');
  }

  Map<String, dynamic> config;
  try {
    final doc = jsonDecode(configFile.readAsStringSync());
    if (doc is! Map) throw const FormatException('Root is not an object.');
    config = Map<String, dynamic>.from(doc);
  } catch (e) {
    AppLogger.logError('Project could not read the room config $configPath', e);
    return failed('The config could not be read: $e');
  }

  final setup = config['SYSTEM_SETUP'];
  final title = (setup is Map ? setup['gui_full_room_name']?.toString() : '')
      ?.trim() ??
      '';

  // The sidecars, each one optional and each one failing on its own. The
  // whole-document merge is the same one the app's loader uses, so a room
  // written before the sidecar split — one file holding every key — reads
  // here exactly as it does there, with no version check.
  Map<String, dynamic>? readPart(String file) {
    if (file.isEmpty || !File(file).existsSync()) return null;
    try {
      final doc = jsonDecode(File(file).readAsStringSync());
      if (doc is! Map) return null;
      return Map<String, dynamic>.from(doc);
    } catch (e) {
      AppLogger.logError('Project could not read the room part $file', e);
      return null;
    }
  }

  final paths = roomSidecarPaths(configPath);
  final parts = <RoomSidecarPart, Map<String, dynamic>?>{
    for (final part in RoomSidecarPart.values) part: readPart(paths[part] ?? ''),
  };

  var flowPath = parts[RoomSidecarPart.flow] == null
      ? ''
      : (paths[RoomSidecarPart.flow] ?? '');

  // The pre-rename flow file, read only when the current name is absent —
  // the same fallback the app makes, so a room documented before the rename
  // prices instead of reading as empty.
  if (parts[RoomSidecarPart.flow] == null) {
    final legacy = path.join(
      path.dirname(configPath),
      '${path.basenameWithoutExtension(configPath)}_avflow.json',
    );
    parts[RoomSidecarPart.flow] = readPart(legacy);
    if (parts[RoomSidecarPart.flow] != null) flowPath = legacy;
  }

  if (parts.values.every((p) => p == null)) {
    // Not an error: an AV-only room that nobody has drawn yet, or a control
    // config with no AV side. It prices at zero and says it is empty.
    return LoadedRoom(
      configPath: configPath,
      title: title,
      model: AvFlowModel(
        nodes: const [],
        cables: const [],
        racks: const [],
        rackSlots: const {},
        canvasSize: const Size(0, 0),
        roomTitle: title,
        unplaced: const [],
      ),
      settings: RoomCostSettings(),
      config: config,
    );
  }

  final doc = mergeRoomSidecar(parts);

  final nodes = <AvNode>[];
  for (final n in (doc['nodes'] as List? ?? [])) {
    if (n is Map) {
      final node = AvNode.fromJson(Map<String, dynamic>.from(n));
      if (node.id.isNotEmpty) nodes.add(node);
    }
  }
  final cables = <AvCable>[];
  for (final c in (doc['cables'] as List? ?? [])) {
    if (c is Map) {
      final cable = AvCable.fromJson(Map<String, dynamic>.from(c));
      if (cable.id.isNotEmpty) cables.add(cable);
    }
  }
  final racks = <RackFrame>[];
  for (final r in (doc['racks'] as List? ?? [])) {
    if (r is Map) {
      final rack = RackFrame.fromJson(Map<String, dynamic>.from(r));
      if (rack.id.isNotEmpty) racks.add(rack);
    }
  }
  final rackItems = <RackItem>[];
  for (final i in (doc['rackItems'] as List? ?? [])) {
    if (i is Map) {
      final item = RackItem.fromJson(Map<String, dynamic>.from(i));
      if (item.id.isNotEmpty) rackItems.add(item);
    }
  }

  final settings = RoomCostSettings();
  final cost = doc['cost'];
  if (cost is Map) settings.readJson(Map<String, dynamic>.from(cost));

  return LoadedRoom(
    configPath: configPath,
    title: title,
    model: AvFlowModel(
      nodes: nodes,
      cables: cables,
      racks: racks,
      rackSlots: const {},
      rackItems: rackItems,
      canvasSize: const Size(0, 0),
      roomTitle: title,
      unplaced: const [],
    ),
    settings: settings,
    config: config,
    flowPath: flowPath,
  );
}

// ---------------------------------------------------------------------------
//  THE ROLLUP
// ---------------------------------------------------------------------------

/// Which section of the quote a master-list part came from. Kept through the
/// merge because a quote is read section by section, and because a cable and a
/// device that share a description must never merge into one line.
enum MasterPartKind { equipment, hardware, cabling, other }

const Map<MasterPartKind, String> kMasterPartKindLabels = {
  MasterPartKind.equipment: 'Equipment',
  MasterPartKind.hardware: 'Rack hardware',
  MasterPartKind.cabling: 'Cabling',
  MasterPartKind.other: 'Other items',
};

/// One room on the job, priced.
class ProjectRoomCost {
  final ProjectRoomRef ref;
  final LoadedRoom room;

  /// Null when [room] could not be read.
  final CostEstimate? estimate;

  /// Devices in this room that no control module will drive — the same rule
  /// the room's own AV and Cost reports print, run headlessly.
  ///
  /// Empty when the caller did not supply a module lookup: the registry is
  /// application data, and a rollup asked for without it should say nothing
  /// about drivers rather than say everything is fine.
  final List<ControlGap> controlGaps;

  const ProjectRoomCost({
    required this.ref,
    required this.room,
    this.estimate,
    this.controlGaps = const [],
  });

  /// What to call this room: the label somebody typed, else the name in the
  /// config, else the file name. Never blank — a quote line with no room on
  /// it cannot be checked against anything.
  String get name {
    if (ref.label.trim().isNotEmpty) return ref.label.trim();
    if (room.title.trim().isNotEmpty) return room.title.trim();
    return ref.fallbackName;
  }

  bool get ok => estimate != null;
  double get total => estimate?.grandTotal ?? 0;
  double get equipmentTotal => estimate?.equipmentTotal ?? 0;
  double get laborTotal => estimate?.laborTotal ?? 0;
  double get laborHours => estimate?.laborHours ?? 0;
}

/// One part, once, with every room that needs it counted onto it.
class MasterPartLine {
  /// The cross-room merge key — see [masterPartKey]. Also what a hand vendor
  /// pin is filed under, so a pin survives a room being renamed, re-drawn or
  /// removed from the job.
  final String key;

  final MasterPartKind kind;
  final String description;
  final String model;
  final String partNumber;
  final String manufacturer;
  final String category;

  /// Total units across every included room.
  final double qty;

  /// Extended total — the SUM of what each room's line came to, never
  /// [qty] × [unitPrice].
  ///
  /// Those two differ whenever one room has a negotiated price override and
  /// another does not, which is common and legitimate. Adding the rooms' own
  /// figures keeps the master list agreeing with the room breakdown to the
  /// cent; recomputing from a single unit price would make the two documents
  /// in the same workbook disagree, which is the one thing a quote cannot do.
  final double total;

  /// The unit price, when every room paid the same one. When they did not
  /// this is the lowest, [maxUnitPrice] the highest, and [priceVaries] is set
  /// so the column can say so rather than print one of them as though it were
  /// the answer.
  final double unitPrice;
  final double maxUnitPrice;
  bool get priceVaries => maxUnitPrice > unitPrice;

  /// Room id -> units for that room. The breakdown a vendor gets asked for
  /// ("which rooms are the eighteen switchers for?") and the one a project
  /// manager checks a delivery against.
  final Map<String, double> qtyByRoom;

  /// The vendor this part is tagged to, and how it got there.
  final ProjectVendor? vendor;
  final VendorTagSource tagSource;

  /// Room id -> units of this part in that room that nothing will drive.
  ///
  /// A part can be driven in one room and not another — the same projector
  /// with its module set in the room that was finished and blank in the one
  /// that was not — so this is per room rather than a flag. That difference is
  /// the whole value of showing it here: "which rooms still need this doing"
  /// is the question, and a single tick could not answer it.
  final Map<String, int> undrivenByRoom;

  /// True when no room could put a real price on this part. Counted into
  /// [ProjectEstimate.unpricedParts] so a master list cannot read as complete
  /// while something on it is a blank.
  final bool unpriced;

  /// Room id -> the keys THAT ROOM files this part under.
  ///
  /// [key] is the cross-room merge key, and a room does not price by it: a
  /// room's own price overrides are filed under its line keys
  /// ([CostLine.key]), which are finer — the same product can group into two
  /// lines in one room. Putting a price on this part for the job means writing
  /// under the keys each room will actually look up, so those keys are carried
  /// here rather than guessed at afterwards.
  ///
  /// A set per room because of exactly that: two lines, two keys, one part.
  final Map<String, Set<String>> lineKeysByRoom;

  const MasterPartLine({
    required this.key,
    required this.kind,
    required this.description,
    required this.model,
    required this.partNumber,
    required this.manufacturer,
    required this.category,
    required this.qty,
    required this.total,
    required this.unitPrice,
    required this.maxUnitPrice,
    required this.qtyByRoom,
    required this.vendor,
    required this.tagSource,
    required this.unpriced,
    this.undrivenByRoom = const {},
    this.lineKeysByRoom = const {},
  });

  /// Units across the job with no control module behind them.
  int get undrivenQty => undrivenByRoom.values.fold(0, (s, n) => s + n);

  /// True when at least one of these has nothing to drive it.
  bool get hasControlGap => undrivenQty > 0;

  /// The rooms this part appears in, most first — how the master list's room
  /// column reads when it has to fit in a cell.
  List<String> roomIdsByQty() {
    final ids = qtyByRoom.keys.toList();
    ids.sort((a, b) {
      final byQty = (qtyByRoom[b] ?? 0).compareTo(qtyByRoom[a] ?? 0);
      return byQty != 0 ? byQty : a.compareTo(b);
    });
    return ids;
  }
}

/// Everything one vendor is being asked to quote.
class VendorPackage {
  /// Null for the untagged package — the parts no rule and no pin claimed.
  /// Kept as a package rather than hidden, because it is the project's own
  /// to-do list: a building is not ready to go out for quotes while it has
  /// one.
  final ProjectVendor? vendor;

  final List<MasterPartLine> lines;
  final double total;

  /// Units across the package — what a vendor sees as "how big is this job".
  final double qty;

  const VendorPackage({
    required this.vendor,
    required this.lines,
    required this.total,
    required this.qty,
  });

  bool get isUntagged => vendor == null;
  String get name => vendor?.name ?? 'Untagged';
}

/// A building, priced.
class ProjectEstimate {
  final BuildingProject project;
  final String currency;

  /// Every room in the project, in project order — including the ones that
  /// failed to read and the ones excluded from the total, each flagged. A
  /// rollup that silently dropped them would be a number nobody can audit.
  final List<ProjectRoomCost> rooms;

  /// Rooms that count toward the totals: included, and readable.
  final List<ProjectRoomCost> costedRooms;

  final List<MasterPartLine> master;
  final List<VendorPackage> vendors;

  /// The sum of each room's own grand total — fees and tax computed per room,
  /// under that room's rates. See the header note on why this is not derived
  /// from a building-wide percentage.
  final double grandTotal;

  final double equipmentTotal;
  final double hardwareTotal;
  final double cablingTotal;
  final double extrasTotal;
  final double laborTotal;
  final double laborHours;
  final double feeTotal;
  final double taxTotal;

  /// Rooms whose file could not be read.
  final int failedRooms;

  /// Master-list parts nothing could price.
  final int unpricedParts;

  /// Master-list parts no vendor claimed.
  final int untaggedParts;

  /// Every undriven device on the job, with the room it is in. The building's
  /// version of the room report's "Devices Without a Control Module" — a room
  /// quoted without anybody noticing that three of its boxes have no driver is
  /// a room that arrives on site and cannot be commissioned, and that is just
  /// as true of nine rooms at once.
  final List<({ProjectRoomCost room, ControlGap gap})> controlGaps;

  /// True when the rooms are not all quoted in the same currency. The totals
  /// are still added — refusing to show a number helps nobody — but the report
  /// says so, because adding dollars to euros is a wrong answer that looks
  /// exactly like a right one.
  final bool mixedCurrency;

  const ProjectEstimate({
    required this.project,
    required this.currency,
    required this.rooms,
    required this.costedRooms,
    required this.master,
    required this.vendors,
    required this.grandTotal,
    required this.equipmentTotal,
    required this.hardwareTotal,
    required this.cablingTotal,
    required this.extrasTotal,
    required this.laborTotal,
    required this.laborHours,
    required this.feeTotal,
    required this.taxTotal,
    required this.failedRooms,
    required this.unpricedParts,
    required this.untaggedParts,
    required this.mixedCurrency,
    this.controlGaps = const [],
  });

  /// Devices, not lines: three undriven displays is three things to fix.
  int get undrivenDevices =>
      controlGaps.fold(0, (s, g) => s + g.gap.qty);

  /// Every part on the job, ignoring which section it came from.
  double get partsTotal =>
      equipmentTotal + hardwareTotal + cablingTotal + extrasTotal;

  /// True when nothing is missing: every room read, every part priced.
  bool get isComplete => failedRooms == 0 && unpricedParts == 0;

  /// The package for one vendor id, or null.
  VendorPackage? packageFor(String vendorId) {
    for (final p in vendors) {
      if (p.vendor?.id == vendorId) return p;
    }
    return null;
  }
}

/// Prices every room in [project] and rolls the result up.
///
/// [rooms] lets a caller supply rooms it has already read — the view re-prices
/// on every vendor edit, and re-reading nine files to answer "what changed
/// about the tags" would make tagging feel broken. When it is null every room
/// is read fresh.
ProjectEstimate computeProjectEstimate({
  required BuildingProject project,
  required String projectPath,
  required AvDeviceLibrary library,
  LaborRateBook? rates,
  BaseCostBook? baseCosts,
  PricingTier tier = PricingTier.msrp,
  Map<String, LoadedRoom>? rooms,

  /// The UI schema's device-count map and the module registry lookup, for the
  /// control-module rule. Both are application data rather than project data,
  /// so they are passed in — and when [moduleForModel] is null the rule is not
  /// run at all. Silence is the right default there: a rollup built without
  /// the registry has no basis for saying a device is undriven, and saying it
  /// anyway would put every device in the building on the list.
  Map<String, String> deviceCountMap = const {},
  String Function(String model)? moduleForModel,
}) {
  final currency = project.currency.isEmpty ? r'$' : project.currency;

  // --- price each room -----------------------------------------------------
  final costed = <ProjectRoomCost>[];
  var mixedCurrency = false;

  for (final ref in project.rooms) {
    final absolute = BuildingProject.resolvePath(ref.configPath, projectPath);
    final room = rooms?[ref.id] ?? readRoomFromDisk(absolute);

    if (!room.ok) {
      costed.add(ProjectRoomCost(ref: ref, room: room));
      continue;
    }

    final estimate = computeRoomCost(
      model: room.model,
      library: library,
      settings: room.settings,
      rates: rates,
      baseCosts: baseCosts,
      tier: tier,
    );

    // Only a room that actually counts can make the book mixed-currency: an
    // excluded alternate quoted in euros is not a problem with this total.
    if (ref.included &&
        room.settings.currency.isNotEmpty &&
        room.settings.currency != currency) {
      mixedCurrency = true;
    }

    costed.add(ProjectRoomCost(
      ref: ref,
      room: room,
      estimate: estimate,
      controlGaps: moduleForModel == null
          ? const []
          : controlGapsForRoom(
              config: room.config,
              model: room.model,
              deviceCountMap: deviceCountMap,
              library: library,
              moduleForModel: moduleForModel,
            ),
    ));
  }

  final included = [
    for (final r in costed) if (r.ref.included && r.ok) r,
  ];

  // --- merge the parts -----------------------------------------------------

  /// One part accumulating across rooms.
  final acc = <String, _PartAccumulator>{};

  /// Room id -> lower-cased model -> undriven units in that room.
  ///
  /// Built once per room rather than searched per line: a building with forty
  /// parts and nine rooms would otherwise walk every room's gap list three
  /// hundred and sixty times to colour one column.
  final undriven = <String, Map<String, int>>{};
  for (final room in included) {
    if (room.controlGaps.isEmpty) continue;
    final byModel = <String, int>{};
    for (final gap in room.controlGaps) {
      final model = gap.model.trim().toLowerCase();
      // A gap with no model on it cannot be matched to a part — it IS the
      // "nobody chose a model" case, and the part it would join does not
      // exist. It still counts on the room's list and in the warning.
      if (model.isEmpty) continue;
      byModel[model] = (byModel[model] ?? 0) + gap.qty;
    }
    if (byModel.isNotEmpty) undriven[room.ref.id] = byModel;
  }

  void take(ProjectRoomCost room, CostLine line, MasterPartKind kind) {
    // A line the room deliberately zeroed is still a line; a line of no units
    // is not a part. Dropping it keeps a master list free of rows that read as
    // "we forgot to order this" when in fact nobody ever wanted any.
    if (line.qty <= 0) return;

    final key = masterPartKey(
      kind: kind.name,
      partNumber: line.partNumber,
      model: line.model,
      manufacturer: line.manufacturer,
      description: line.description,
    );
    acc
        .putIfAbsent(
          key,
          () => _PartAccumulator(key: key, kind: kind, first: line),
        )
        .add(
          room.ref.id,
          line,
          // Only EQUIPMENT can be undriven. A length of cable and a blanking
          // plate have no control module and never wanted one, and letting the
          // model match put a flag on them would bury the real ones.
          undriven: kind == MasterPartKind.equipment
              ? (undriven[room.ref.id]?[line.model.trim().toLowerCase()] ?? 0)
              : 0,
        );
  }

  for (final room in included) {
    final e = room.estimate!;
    for (final l in e.equipment) {
      take(room, l, MasterPartKind.equipment);
    }
    for (final l in e.hardware) {
      take(room, l, MasterPartKind.hardware);
    }
    for (final l in e.cabling) {
      take(room, l, MasterPartKind.cabling);
    }
    for (final l in e.extras) {
      take(room, l, MasterPartKind.other);
    }
  }

  // --- tag and sort --------------------------------------------------------
  final master = <MasterPartLine>[];
  var unpricedParts = 0;
  var untaggedParts = 0;

  for (final a in acc.values) {
    final tag = project.vendorForPart(
      a.key,
      manufacturer: a.manufacturer,
      category: a.category,
    );
    if (tag.vendor == null) untaggedParts++;
    if (a.unpriced) unpricedParts++;

    master.add(MasterPartLine(
      key: a.key,
      kind: a.kind,
      description: a.description,
      model: a.model,
      partNumber: a.partNumber,
      manufacturer: a.manufacturer,
      category: a.category,
      qty: a.qty,
      total: a.total,
      unitPrice: a.lowUnitPrice,
      maxUnitPrice: a.maxUnitPrice,
      qtyByRoom: a.qtyByRoom,
      vendor: tag.vendor,
      tagSource: tag.source,
      unpriced: a.unpriced,
      undrivenByRoom: a.undrivenByRoom,
      lineKeysByRoom: a.lineKeysByRoom,
    ));
  }

  master.sort(_compareMasterLines);

  // --- split by vendor -----------------------------------------------------
  final byVendor = <String, List<MasterPartLine>>{};
  for (final line in master) {
    byVendor.putIfAbsent(line.vendor?.id ?? '', () => []).add(line);
  }

  final packages = <VendorPackage>[];
  // In the project's own vendor order, so the workbook's tabs are in the order
  // the vendor list is on screen rather than in whatever order the parts
  // happened to merge.
  for (final v in project.vendors) {
    final lines = byVendor[v.id] ?? const <MasterPartLine>[];
    if (lines.isEmpty) continue;
    packages.add(VendorPackage(
      vendor: v,
      lines: lines,
      total: lines.fold(0.0, (s, l) => s + l.total),
      qty: lines.fold(0.0, (s, l) => s + l.qty),
    ));
  }
  // Untagged last: it is the exception list, and it belongs after the work.
  final loose = byVendor[''] ?? const <MasterPartLine>[];
  if (loose.isNotEmpty) {
    packages.add(VendorPackage(
      vendor: null,
      lines: loose,
      total: loose.fold(0.0, (s, l) => s + l.total),
      qty: loose.fold(0.0, (s, l) => s + l.qty),
    ));
  }

  double sum(double Function(CostEstimate) of) =>
      included.fold(0.0, (s, r) => s + of(r.estimate!));

  return ProjectEstimate(
    project: project,
    currency: currency,
    rooms: costed,
    costedRooms: included,
    master: master,
    vendors: packages,
    grandTotal: sum((e) => e.grandTotal),
    equipmentTotal: sum((e) => e.equipmentTotal),
    hardwareTotal: sum((e) => e.hardwareTotal),
    cablingTotal: sum((e) => e.cablingTotal),
    extrasTotal: sum((e) => e.extrasTotal),
    laborTotal: sum((e) => e.laborTotal),
    laborHours: sum((e) => e.laborHours),
    feeTotal: sum((e) => e.feeTotal),
    taxTotal: sum((e) => e.tax),
    failedRooms: costed.where((r) => !r.ok).length,
    unpricedParts: unpricedParts,
    untaggedParts: untaggedParts,
    mixedCurrency: mixedCurrency,
    controlGaps: [
      for (final room in included)
        for (final gap in room.controlGaps) (room: room, gap: gap),
    ],
  );
}

/// Master list order: section, then manufacturer, then description.
///
/// Section first because that is how a quote is read and how the sheets are
/// broken up. Manufacturer second because within a section, the thing a buyer
/// scans for is the maker. The key is the last tiebreak for the same reason
/// [compareByManufacturer] uses it — Dart's sort is not stable, and a list
/// whose rows swap places on every rebuild is one nobody can proofread.
int _compareMasterLines(MasterPartLine a, MasterPartLine b) {
  final byKind = a.kind.index.compareTo(b.kind.index);
  if (byKind != 0) return byKind;
  final makerA = a.manufacturer.trim();
  final makerB = b.manufacturer.trim();
  if (makerA.isEmpty != makerB.isEmpty) return makerA.isEmpty ? 1 : -1;
  final byMaker = makerA.toLowerCase().compareTo(makerB.toLowerCase());
  if (byMaker != 0) return byMaker;
  final byName =
      a.description.toLowerCase().compareTo(b.description.toLowerCase());
  return byName != 0 ? byName : a.key.compareTo(b.key);
}

/// One part being built up across rooms. Private: the finished thing is
/// [MasterPartLine], and nothing outside should be able to hold a half-summed
/// one.
class _PartAccumulator {
  final String key;
  final MasterPartKind kind;

  String description;
  String model;
  String partNumber;
  String manufacturer;
  String category;

  double qty = 0;
  double total = 0;
  double minUnitPrice = double.infinity;
  double maxUnitPrice = 0;
  final Map<String, double> qtyByRoom = {};
  final Map<String, int> undrivenByRoom = {};
  final Map<String, Set<String>> lineKeysByRoom = {};

  /// Set while every room that carries this part failed to price it. One room
  /// with a real price is enough to make the part priced — the total is then
  /// short rather than blank, and the room breakdown shows which.
  bool unpriced = true;

  _PartAccumulator({
    required this.key,
    required this.kind,
    required CostLine first,
  })  : description = first.description,
        model = first.model,
        partNumber = first.partNumber,
        manufacturer = first.manufacturer,
        category = first.category;

  void add(String roomId, CostLine line, {int undriven = 0}) {
    qty += line.qty;
    total += line.total;
    qtyByRoom[roomId] = (qtyByRoom[roomId] ?? 0) + line.qty;
    // The key this room prices by, kept so a price set on the job can be
    // written where the room will look for it.
    (lineKeysByRoom[roomId] ??= <String>{}).add(line.key);
    // Assigned rather than added: the figure is the room's whole count for
    // this model, and a model that groups into two lines in one room (one
    // excluded from cost, say) would otherwise count its gaps twice.
    if (undriven > 0) undrivenByRoom[roomId] = undriven;

    if (line.source != PriceSource.none) {
      unpriced = false;
      // Only real prices set the range. A line nobody priced is a zero, and
      // letting it in would make every part with one unpriced room read as
      // "price varies, from $0".
      if (line.unitPrice < minUnitPrice) minUnitPrice = line.unitPrice;
      if (line.unitPrice > maxUnitPrice) maxUnitPrice = line.unitPrice;
    }

    // The fullest identification any room had. Two rooms can describe the same
    // part with different amounts of detail — one drawn before the catalog
    // entry got its part number, one after — and the master list should carry
    // the better of the two rather than whichever room sorted first.
    if (partNumber.trim().isEmpty && line.partNumber.trim().isNotEmpty) {
      partNumber = line.partNumber;
    }
    if (model.trim().isEmpty && line.model.trim().isNotEmpty) {
      model = line.model;
    }
    if (manufacturer.trim().isEmpty && line.manufacturer.trim().isNotEmpty) {
      manufacturer = line.manufacturer;
    }
    if (category.trim().isEmpty && line.category.trim().isNotEmpty) {
      category = line.category;
    }
  }

  /// The low end of the price range, or 0 when nothing priced it.
  double get lowUnitPrice => minUnitPrice.isFinite ? minUnitPrice : 0;
}
