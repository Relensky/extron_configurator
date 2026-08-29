import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'app_paths.dart';
import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'equipment_lifecycle.dart'
    show equipmentIsTracked, equipmentNeverReplaced;
import 'responsibility_matrix.dart';
import 'base_costs.dart';
import 'config_dictionary.dart';
import 'config_key_mapper.dart';
import 'flow_rules.dart';
import 'cabling_schematic.dart';
import 'building_project.dart';
import 'cost_estimate.dart';
import 'labor_rates.dart';
import 'model_swap.dart' as swap;
import 'av_flow_swap_dialogs.dart' show applyModelSwap, applyControlSwap;
import 'project_estimate.dart';
import 'project_swap.dart';
import 'layout_tools.dart';
import 'room_locations.dart';
import 'room_presets.dart';
import 'room_sidecar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'secret_store.dart';
import 'sftp_client.dart';
import 'ui_schema.dart';
import 'package:file_picker/file_picker.dart';

/// The navigation rail's tabs, in rail order.
///
/// Several places key off the selected tab (the view switch, the landing-screen
/// bypass for App Config, the screenshot file name, the diagram capture). They
/// used to compare bare integers, which meant inserting a tab silently
/// repointed all of them — so the index lives here once and everything reads
/// it through [index].
///
/// Here rather than in main.dart because the number it stands for is stored on
/// the provider ([AppStateProvider.selectedTabIndex]), and the pages that read
/// it should not have to import the app's entry point to say which tab they
/// are.
enum AppTab {
  // THE TWO MONEY TABS FIRST, and the job above the room.
  //
  // The rail used to open on the Wizard because a session started by building
  // a room. A session now starts by opening a JOB: the project says which
  // rooms there are, and the room you work on is picked from it. So the tab
  // that answers "what is this building" comes first, the tab that answers
  // "what does this room come to" second, and the tabs that build a room
  // follow — which is the order the work is actually done in.
  project('project'),
  cost('cost'),
  // What the room already HAS, and how old it is. Beside the cost of building
  // it because the two are the same question at two ends of the room's life —
  // what it costs to put in, and what year it has to be put in again.
  lifecycle('lifecycle'),
  wizard('wizard'),
  devices('devices'),
  system('system'),
  // Beside System, because the two are the same document seen two ways: the
  // form and the file it writes. Somebody checking what a field did to the
  // config should not have to cross nine drawing tabs to look.
  rawJson('raw_json'),
  schematic('schematic'),
  avFlow('av_flow'),
  floorPlan('floor_plan'),
  cabling('cabling'),
  racks('racks'),
  deviceEditor('device_editor'),
  // The two documents that describe how the app itself behaves, next to the
  // catalog for the same reason it is there: they are about every room rather
  // than about the room that happens to be open.
  schemaEditor('schema_editor'),
  flowRules('flow_rules'),
  appConfig('app_config');

  /// Token used in screenshot file names.
  final String token;
  const AppTab(this.token);

  /// Tabs that work with no room loaded. App Config is settings; the Device
  /// Editor is the equipment catalog — both are about the app and the price
  /// list, not about a room, so the "No Configuration Loaded" screen must not
  /// stand in front of them.
  bool get worksWithoutConfig =>
      this == AppTab.appConfig ||
      this == AppTab.deviceEditor ||
      this == AppTab.schemaEditor ||
      this == AppTab.flowRules ||
      // A project is a list of room FILES. It prices them off disk and needs
      // no room open — and the case for opening it with none is the strongest
      // one there is: reviewing a building's quote is a thing somebody does
      // without wanting to edit any room in it.
      this == AppTab.project;
}

/// How far along a room is.
///
/// A room is usually specified long before anybody writes its control config —
/// the drawings, the rack and the budget all exist first. [RoomMode.avOnly]
/// says that is where this one is: it has a building, a room number and a list
/// of devices, and no control system yet. The System and Raw JSON tabs are
/// about the processor's config file, so they step out of the way; the
/// schematic, the AV flow, the racks and the costs all still work, because
/// they are about the room rather than the processor.
///
/// The devices are still recorded in the normal config blocks, so nothing has
/// to be re-entered when the control side is finally built — the only thing
/// missing is the python module for each device, which the app flags.
enum RoomMode { full, avOnly }

RoomMode roomModeFromName(String? name) =>
    name?.trim().toLowerCase() == 'avonly' ? RoomMode.avOnly : RoomMode.full;

const Map<RoomMode, String> kRoomModeLabels = {
  RoomMode.full: 'Control system configured',
  RoomMode.avOnly: 'AV only - no control system yet',
};

/// The config's live device blocks, in device-family order: for each dev_
/// count key, the sections that actually exist up to that count.
///
/// Top-level because the Devices tab, the Schematic tab, the AV Flow tab and
/// the provider's own missing-module check all need the same answer — "which
/// devices does this room really have?" — and they must agree.
List<String> activeDeviceKeysIn(
    Map<String, dynamic> config, Map<String, String> map) {
  final List<String> activeKeys = [];
  final systemSetup = config['SYSTEM_SETUP'] ?? {};

  // The hardware map comes from the UI schema's "device_types", so families
  // added in ui_schema.json are covered without a recompile.
  map.forEach((countKey, prefix) {
    if (systemSetup is Map && systemSetup.containsKey(countKey)) {
      final countVal = systemSetup[countKey];
      final int count = (countVal.toString().toLowerCase() == 'yes')
          ? 1
          : (int.tryParse(countVal.toString()) ?? 0);

      for (int i = 1; i <= count; i++) {
        final String expectedKey = '$prefix$i';
        if (config.containsKey(expectedKey)) activeKeys.add(expectedKey);
      }
    }
  });
  return activeKeys;
}

/// One device in the room whose control module has not been chosen yet.
typedef UnmodularDevice = ({String key, String name, String model});

/// Why a device's model and its python module do not go together — see
/// [AppStateProvider.deviceModelModuleFault].
///
/// Two cases rather than one, because the sentence to print is different and
/// so is the fix: one is a driver nobody has chosen, the other is a driver
/// that is demonstrably for something else.
enum ModelModuleFault {
  /// A model is set and no module is. Where a swap onto a model no driver
  /// claims leaves the block — see [AppStateProvider.setModelWithoutModule].
  noModule,

  /// A module is set, it says which models it covers, and this is not one of
  /// them. The device the config describes and the device the processor would
  /// talk to are two different products.
  unclaimedModel,

  /// No module, and none is wanted: the CATALOG says this product never needs
  /// one. A laptop plate, a passive splitter, a mount.
  ///
  /// NOT A FAULT, and the only member here that is not. It is on this list
  /// because the device page has one slot for "what is the story with this
  /// block's module", and the answer "somebody has already decided this needs
  /// none" belongs in it — quietly, as a note, so the block can be confirmed
  /// against the room file without being nagged about.
  noModuleNeeded,
}

/// A device whose model and module disagree, with everything the message
/// needs: [claims] is what the module says it covers, empty for [noModule].
typedef ModelModuleMismatch = ({
  ModelModuleFault fault,
  String model,
  String module,
  List<String> claims,
});

/// The connection styles a python driver may publish its own DEVICE_INFO
/// defaults for, in the spelling [AppStateProvider.normalizeComTypeName]
/// produces. These are the five the schema's com_type dropdown offers; a block
/// named anything else in a driver is ignored rather than guessed at, so a
/// typo shows up as "nothing loaded" instead of as a silent write.
const Set<String> kComTypeDefaultNames = {
  'network',
  'serial',
  'serialoverethernet',
  'http',
  // The Extron SP bus (a NAVigator). Nothing to publish but the com_type
  // itself — the device is addressed by its spdevice alias — but the block
  // has to be recognised or a driver that declares it looks like a typo.
  'spi',
};

/// The normalized block name -> the com_type value the config and the schema's
/// dropdown actually use, in the order that dropdown lists them. What the
/// driver-defaults review offers as the connection to compare against.
const Map<String, String> kComTypeStyleLabels = {
  'serial': 'Serial',
  'serialoverethernet': 'SerialOverEthernet',
  'network': 'Network',
  'http': 'HTTP',
  'spi': 'SPI',
};

/// Core State Manager for the Room Configuration Application
/// The control schematic's three generated boxes. Named because they are now
/// referred to from two layers — the diagram draws them, and the room records
/// which of them its AV LAN and its touch panel land on — and a drop that
/// silently stopped working because one end was spelled 'Processor' would be
/// invisible until somebody read the drawing closely.
const String kSchematicProcessor = 'PROCESSOR';
const String kSchematicIdf = 'IDF';
const String kSchematicTouchPanel = 'TOUCHPANEL';

class AppStateProvider extends ChangeNotifier {
  /// Whether this room has a control system yet. See [RoomMode]; persisted in
  /// the AV sidecar, because for an AV-only room that is the only document
  /// that exists.
  RoomMode roomMode = RoomMode.full;

  bool get isAvOnlyRoom => roomMode == RoomMode.avOnly;

  void setRoomMode(RoomMode mode) {
    if (roomMode == mode) return;
    roomMode = mode;
    AppLogger.logInfo('Room mode set to ${kRoomModeLabels[mode]}.');
    notifyListeners();
  }

  /// The device the Devices tab should open on, by config section key.
  ///
  /// A ROOM IS FOURTEEN TABS. Every list in this app that reports a fault in a
  /// device ends with somebody opening the room to fix it, and "open the room"
  /// landed on the first tab — so the last step of acting on a flag was
  /// reading fourteen tab labels to find the device the flag was about. The
  /// lists know which device they mean; this is how they say so.
  ///
  /// Session-only, and a REQUEST rather than a selection: the tab honours it
  /// when it next builds and the reader is free to move off it, which is why
  /// nothing clears it afterwards. A key this room does not have is ignored.
  String requestedDeviceKey = '';

  /// Opens the Devices tab on [deviceKey] — see [requestedDeviceKey].
  void requestDevice(String deviceKey) {
    if (requestedDeviceKey == deviceKey) return;
    requestedDeviceKey = deviceKey;
    notifyListeners();
  }

  // --------------------------------------------------------------------------
  //  WHICH PANE OF THE PROJECT TAB
  // --------------------------------------------------------------------------
  //  The same problem [requestedDeviceKey] solves one level up. The Project tab
  //  is nine panes, and every route into it landed on Rooms - so a reader who
  //  pressed a figure on the campus calendar, which is a replacement-plan
  //  question, arrived at a list of room files and had to find the plan
  //  themselves. The thing that sent them there knows which pane it meant.
  //
  //  BY NAME, not by the enum: the panes are private to project_view.dart and
  //  should stay that way. A name that pane list does not have is ignored, so
  //  a rename cannot crash a caller - it just stops steering.

  /// The pane the Project tab should open on, by its enum name ('lifecycle').
  String requestedProjectPane = '';

  /// Bumped on every request, so asking for the SAME pane twice still moves
  /// the tab. Without it, a reader who pressed a campus figure, wandered off to
  /// Parts and pressed another figure would be handed Parts again: the request
  /// would not have changed, and the tab honours changes.
  int projectPaneRequestId = 0;

  /// Opens the Project tab on [pane] — see [requestedProjectPane].
  void requestProjectPane(String pane) {
    requestedProjectPane = pane;
    projectPaneRequestId++;
    notifyListeners();
  }

  /// Devices in this room with no python module chosen — the list the app
  /// nags about.
  ///
  /// This is the whole point of letting a room be drawn before its control
  /// system exists: the devices are real and recorded, and the ONE thing
  /// missing when the control side finally gets built is which driver each of
  /// them runs. A processor cannot talk to a device with no module, so an
  /// unanswered entry here is a room that will not commission.
  List<UnmodularDevice> get devicesMissingModules =>
      _unmodularDevices(needingOne: true);

  /// Devices with no module that are not SUPPOSED to have one.
  ///
  /// A NOTE, NOT A WARNING. Somebody has already been through these and said
  /// so — the catalog entry carries `neverControlled` (see
  /// [avModelNeverControlled]), which is a decision about the product and not
  /// about this room. Carrying them on the nag list made that decision
  /// worthless: the count stayed up, the banner stayed red, and the only way
  /// to clear it was to leave the room wrong.
  ///
  /// They are still listed, because "the laptop plates have no driver" is a
  /// thing somebody checking a room file wants confirmed rather than
  /// discovered. See the Devices tab, which prints the same fact on the block
  /// itself as [ModelModuleFault.noModuleNeeded].
  List<UnmodularDevice> get devicesNeedingNoModule =>
      _unmodularDevices(needingOne: false);

  /// The config's module-less device blocks, split by whether the catalog says
  /// a module is wanted at all.
  List<UnmodularDevice> _unmodularDevices({required bool needingOne}) {
    final out = <UnmodularDevice>[];
    for (final key in activeDeviceKeysIn(roomConfig, uiSchema.deviceCountMap)) {
      final dev = roomConfig[key];
      if (dev is! Map) continue;
      final module = dev['module']?.toString().trim() ?? '';
      if (module.isNotEmpty) continue;
      final model = dev['model']?.toString() ?? '';
      if (avModelNeverControlled(model) == needingOne) continue;
      out.add((
        key: key,
        name: dev['name']?.toString() ?? key,
        model: model,
      ));
    }
    return out;
  }

  /// Whether [deviceKey]'s model and its python module disagree, and how —
  /// null when they are fine, or when there is not enough to judge on.
  ///
  /// THE BANNER ON THE DEVICES TAB. A device block names a product and names
  /// the driver that talks to it, and nothing kept the two together: a model
  /// could be retyped, or swapped from the Cost tab, and the module underneath
  /// went on naming a driver for the box that used to be there. That config
  /// looks complete — every field filled in — which is exactly why it is the
  /// one nobody re-checks, and it commissions a room as the wrong device.
  ///
  /// Deliberately quiet in the three cases where it cannot know:
  ///
  ///   * NO MODEL YET. An unfinished device is not a wrong one.
  ///   * A MODULE THAT DECLARES NO MODELS. Plenty of drivers list none, and
  ///     the modules path may not even have been read yet; "this module says
  ///     nothing about models" is not evidence against the model.
  ///   * A MODEL THE MODULE DOES LIST, however it is capitalized — the same
  ///     forgiveness [modelEntryFor] gives, because people type 'tr311hw'.
  ///
  /// So a red banner here always means something a person can act on.
  ModelModuleMismatch? deviceModelModuleFault(String deviceKey) {
    final dev = roomConfig[deviceKey];
    if (dev is! Map) return null;
    final model = dev['model']?.toString().trim() ?? '';
    if (model.isEmpty) return null;
    final module = dev['module']?.toString().trim() ?? '';
    if (module.isEmpty) {
      return (
        // A product the catalog says never needs one. The block is finished;
        // the page says so instead of asking for a driver that will never
        // exist.
        fault: avModelNeverControlled(model)
            ? ModelModuleFault.noModuleNeeded
            : ModelModuleFault.noModule,
        model: model,
        module: '',
        claims: const <String>[],
      );
    }
    final declared = moduleModels[moduleStem(module)];
    if (declared == null || declared.isEmpty) return null;
    final wanted = model.toLowerCase();
    for (final m in declared) {
      if (m.trim().toLowerCase() == wanted) return null;
    }
    return (
      fault: ModelModuleFault.unclaimedModel,
      model: model,
      module: module,
      claims: List<String>.unmodifiable(declared),
    );
  }

  /// Devices drawn on the AV canvas that the room config knows nothing about.
  ///
  /// A room specified from the cost estimator, or one where somebody added a
  /// box by hand, ends up with equipment on the diagram and no control block
  /// behind it — so not only no python module, but nowhere to put one. These
  /// are flagged alongside [devicesMissingModules] because they are the same
  /// problem one step earlier, and because the moment to notice is now rather
  /// than at commissioning.
  ///
  /// Jack fields and patch panels are left out: they are passive, and a
  /// processor was never going to talk to them.
  List<UnmodularDevice> get avDevicesWithoutControl {
    final configured = activeDeviceKeysIn(
      roomConfig,
      uiSchema.deviceCountMap,
    ).toSet();
    return [
      for (final n in avNodes)
        // A box nothing was ever going to drive is not a gap in the config —
        // see [avNodeIsUncontrolled].
        if (!n.isJackField &&
            !avNodeIsUncontrolled(n) &&
            !configured.contains(n.id))
          (key: n.id, name: n.label, model: n.model),
    ];
  }

  /// True when nothing in the room will ever talk to this box, from either of
  /// the two directions that can say so: THIS box was excluded by hand on the
  /// diagram ([AvNode.excludeFromControl]), or the PRODUCT is uncontrollable
  /// wherever it turns up ([AvDeviceTemplate.neverControlled]).
  ///
  /// One question, asked in one place, because four things ask it — the
  /// control-gap report, the config prefill, the estimate's per-row flag and
  /// the count on the estimate's header — and three answers to it would be
  /// three lists of "missing" devices that disagree.
  bool avNodeIsUncontrolled(AvNode node) =>
      node.excludeFromControl || avModelNeverControlled(node.model);

  /// True when the catalog says this model has no control interface at all.
  bool avModelNeverControlled(String model) =>
      model.trim().isNotEmpty &&
      (avDeviceLibrary.templateForModel(model)?.neverControlled ?? false);

  // --- Application Paths & Settings ---
  String modulesPath = '';
  String processorsFilePath = '';
  String rootFolderPath = ''; 
  String buildingsFilePath = '';
  String templateFilePath = '';
  String uiSchemaPath = ''; // Optional path to ui_schema.json (GUI field definitions)
  String keyMapPath = '';   // Optional path to key_map.json (legacy key translation)
  /// Optional path to av_devices.json — the connector sets the AV Flow draws
  /// ports from and the price list the estimate reads.
  ///
  /// Worth pointing somewhere OFF this machine: one catalog on a share is one
  /// price list for the department, and a save merges another editor's
  /// changes rather than overwriting them (see [AvDeviceLibrary.save]).
  String avDevicesFilePath = '';
  /// Optional path to av_flow_rules.json — how the AV Flow tab turns a config
  /// into a drawing. Same reason to point it at a share as the catalog: the
  /// rules are a description of how this shop builds rooms, not a per-machine
  /// preference.
  String flowRulesFilePath = '';
  String documentationPath = ''; // Folder of per-module PDF manuals (blank = <root>/documentation)

  // --- Processor connection settings (App Config > Processor Connection) ---
  // Defaults are the Extron standards; editable for nonstandard processors.
  String sftpUsername = 'admin';
  String sftpPort = '22022';
  String sftpRemoteConfigPath = '/config.json';

  /// Shared processor admin password, pre-filled into the SFTP dialogs when
  /// [useDefaultProcessorPassword] is on — the rooms are typically all on one
  /// standard credential, and retyping it per transfer is the slow part.
  ///
  /// This field is the in-memory copy only. The stored copy lives in the OS
  /// keystore (see [SecretStore]) and NEVER in app_config.json, so the settings
  /// file stays hand-editable without carrying a credential. On Windows the
  /// keystore encrypts it against the logged-in account.
  String defaultProcessorPassword = '';

  /// Whether to pre-fill [defaultProcessorPassword]. Off unless turned on, so
  /// the password is never stored or used by accident.
  bool useDefaultProcessorPassword = false;

  /// Turning the toggle OFF also forgets the saved password — cleared from
  /// memory AND deleted from the keystore — so switching it off is enough to
  /// get the credential off the machine.
  Future<void> setUseDefaultProcessorPassword(bool value) async {
    useDefaultProcessorPassword = value;
    if (!value) {
      defaultProcessorPassword = '';
      await _secrets.delete(SecretKeys.processorPassword);
    }
    notifyListeners();
    await _persistSettings();
  }

  /// Serializes keystore writes. The field calls this on every keystroke, so
  /// without a queue two writes can be in flight at once and an earlier, shorter
  /// value can land last — leaving a truncated password stored. Chaining them
  /// makes the last keystroke the last write.
  Future<void> _passwordWrites = Future.value();

  /// Saves the processor password to the OS keystore (and to the in-memory copy
  /// the SFTP dialogs read). Returns false when the keystore refused it, which
  /// the UI surfaces rather than pretending the password was saved.
  Future<bool> setDefaultProcessorPassword(String value) {
    defaultProcessorPassword = value;
    notifyListeners();
    final result = Completer<bool>();
    _passwordWrites = _passwordWrites.then((_) async {
      result.complete(await _secrets.write(SecretKeys.processorPassword, value));
    });
    return result.future;
  }

  /// Pulls the saved password out of the keystore into memory at startup, and
  /// migrates one that an older build wrote into app_config.json as plain text:
  /// moved into the keystore, then stripped from the JSON on the next save.
  /// [savedJson] is the settings file as parsed.
  Future<void> _loadProcessorPassword(Map<String, dynamic> savedJson) async {
    final legacy = savedJson['defaultProcessorPassword']?.toString() ?? '';
    if (legacy.isNotEmpty) {
      final moved = await _secrets.write(SecretKeys.processorPassword, legacy);
      defaultProcessorPassword = legacy;
      AppLogger.logInfo(moved
          ? 'Moved the saved processor password out of app_config.json into the '
              'OS keystore; the plain-text copy is dropped on the next save.'
          : 'Could not move the saved processor password into the OS keystore - '
              'it stays in app_config.json for now.');
      return;
    }
    defaultProcessorPassword =
        await _secrets.read(SecretKeys.processorPassword) ?? '';
  }

  /// The password the SFTP dialogs should open with: the saved default when the
  /// toggle is on and one is set, otherwise blank (type it per transfer).
  String get autofillProcessorPassword =>
      useDefaultProcessorPassword ? defaultProcessorPassword : '';

  /// Parsed SFTP port with the Extron default as the fallback.
  int get effectiveSftpPort => int.tryParse(sftpPort) ?? 22022;

  // ---------------------------------------------------------------------
  //  DEFAULT PATH RESOLUTION
  //  Every external file falls back to the Root Folder when no explicit
  //  path has been chosen in App Config. The Root Folder itself falls back
  //  to the app's base directory (see _appBaseDir). Python modules default
  //  to the "devices" sub-folder of the root. The UI should always read
  //  these effective* getters instead of the raw fields.
  // ---------------------------------------------------------------------

  /// Cached result of [_appBaseDir]; the base directory never changes during
  /// a run, and resolving it touches the disk, so it is computed once.
  static String? _cachedAppBaseDir;

  /// The default base folder for every blank path AND for app_config.json.
  ///
  /// It must be a STABLE, WRITABLE location: the process working directory
  /// ([Directory.current]) is neither. When a packaged Windows app is
  /// launched from a shortcut or the Start menu, the working directory is
  /// often C:\Windows\System32 — the wrong place to look for the shipped
  /// config.json / processors.json, and one the app cannot write settings
  /// to. So this resolves, in order:
  ///   1. A directory that already holds our own app_config.json — keeps
  ///      settings continuity across launches regardless of how the app was
  ///      started (checks the working dir, then the executable's folder).
  ///   2. A directory that holds the app's shipped data files (config.json,
  ///      ui_schema.json, processors.json, buildings.json, or a devices/
  ///      folder) — the real root the user drops files into. In dev
  ///      (`flutter run`) that is the project root = the working directory.
  ///   3. True first run with nothing placed yet: the executable's own
  ///      folder, because it is stable and writable no matter how the app
  ///      was launched. Falls back to the working directory only when the
  ///      executable path can't be resolved.
  static String _appBaseDir() {
    if (_cachedAppBaseDir != null) return _cachedAppBaseDir!;

    final List<String> candidates = [Directory.current.path];
    try {
      candidates.add(File(Platform.resolvedExecutable).parent.path);
    } catch (_) {}

    // 1. Prefer wherever our settings file already lives.
    for (final d in candidates) {
      if (File(path.join(d, 'app_config.json')).existsSync()) {
        return _cachedAppBaseDir = d;
      }
    }
    // 2. Otherwise a directory that clearly holds the app's data files.
    bool looksLikeData(String d) =>
        File(path.join(d, 'config.json')).existsSync() ||
        File(path.join(d, 'ui_schema.json')).existsSync() ||
        File(path.join(d, 'processors.json')).existsSync() ||
        File(path.join(d, 'buildings.json')).existsSync() ||
        Directory(path.join(d, 'devices')).existsSync();
    for (final d in candidates) {
      if (looksLikeData(d)) return _cachedAppBaseDir = d;
    }
    // 3. Nothing placed yet — use the executable's folder when known.
    return _cachedAppBaseDir =
        candidates.length > 1 ? candidates[1] : candidates[0];
  }

  /// Root Folder setting, falling back to the app's base directory.
  String get effectiveRootFolder =>
      rootFolderPath.isNotEmpty ? rootFolderPath : _appBaseDir();

  /// Python modules folder: explicit choice, else `<root>/devices`.
  String get effectiveModulesPath => modulesPath.isNotEmpty
      ? modulesPath
      : path.join(effectiveRootFolder, 'devices');

  /// PDF manuals folder: explicit choice, else `<root>/documentation`.
  /// Each module's manual is `<module file name>.pdf` in this folder.
  String get effectiveDocumentationPath => documentationPath.isNotEmpty
      ? documentationPath
      : path.join(effectiveRootFolder, 'documentation');

  /// processors.json: explicit choice, else `<root>/processors.json`.
  String get effectiveProcessorsFilePath => processorsFilePath.isNotEmpty
      ? processorsFilePath
      : path.join(effectiveRootFolder, 'processors.json');

  /// buildings.json: explicit choice, else `<root>/buildings.json`.
  String get effectiveBuildingsFilePath => buildingsFilePath.isNotEmpty
      ? buildingsFilePath
      : path.join(effectiveRootFolder, 'buildings.json');

  /// Template config: explicit choice, else `<root>/config.json`.
  String get effectiveTemplateFilePath => templateFilePath.isNotEmpty
      ? templateFilePath
      : path.join(effectiveRootFolder, 'config.json');

  /// ui_schema.json / key_map.json: use the root-folder copy only when it
  /// actually exists there, so the loaders' own working-dir / executable
  /// search still applies otherwise (returns '' to trigger that search).
  String _resolveOptionalFile(String explicit, String filename) {
    if (explicit.isNotEmpty) return explicit;
    if (rootFolderPath.isNotEmpty) {
      final candidate = path.join(rootFolderPath, filename);
      if (File(candidate).existsSync()) return candidate;
    }
    return '';
  }

  /// Display-oriented resolved locations for the setup dialog / App Config
  /// hints (explicit choice, else the root-folder default location).
  String get effectiveUiSchemaPath => uiSchemaPath.isNotEmpty
      ? uiSchemaPath
      : path.join(effectiveRootFolder, 'ui_schema.json');
  String get effectiveKeyMapPath => keyMapPath.isNotEmpty
      ? keyMapPath
      : path.join(effectiveRootFolder, 'key_map.json');

  // ---------------------------------------------------------------------
  //  SETTINGS PERSISTENCE (app_config.json)
  //  Every application setting (file paths, SFTP connection, theme,
  //  toggles) lives in a plain, hand-editable app_config.json — kept in the
  //  per-user settings folder (%APPDATA%\RoomConfigBuilder on Windows) so
  //  that installing a new build never overwrites it. Its exact location is
  //  shown on the App Config tab. The file is created automatically with
  //  defaults on the very first launch, so startup never depends on the user
  //  picking a folder or location. A file left next to the app by an older
  //  version is migrated in once, as are settings saved by even older
  //  versions in the OS store (SharedPreferences).
  // ---------------------------------------------------------------------

  /// Absolute path of the app_config.json in use (shown in App Config).
  String settingsFilePath = '';

  /// True once first-run setup has been completed (persisted in the file).
  bool _initialSetupComplete = false;

  /// The app folder copy of app_config.json — where settings used to live, and
  /// still the file [_appBaseDir] looks for when working out the app's root.
  static String _legacySettingsFilePath() =>
      path.join(_appBaseDir(), 'app_config.json');

  /// Per-user settings folder: %APPDATA%\RoomConfigBuilder on Windows, else
  /// ~/.room_config_builder. Falls back to the app folder when the environment
  /// gives us nothing to work with.
  static String _userSettingsDir() =>
      userDataDirOrNull() ?? _appBaseDir();

  /// Where app_config.json is read from and written to.
  ///
  /// It deliberately does NOT live next to the executable any more. Deploying a
  /// new build by copying the output folder over the installed one replaced the
  /// settings file along with it, which is how toggles like "Confirm before
  /// deleting settings" and the processor-password autofill kept reverting to
  /// an old build's values. A per-user location is outside anything a deploy
  /// overwrites, so settings carry over across updates.
  ///
  /// A file left in the app folder by an earlier version is migrated on the
  /// first launch (see [_migrateLegacySettingsFile]) and then left alone —
  /// [_appBaseDir] still uses its presence to resolve the app's root folder.
  static String _resolveSettingsFilePath() =>
      path.join(_userSettingsDir(), 'app_config.json');

  /// The resolved app_config.json location, for tests that guard it against
  /// drifting back next to the executable.
  @visibleForTesting
  static String resolvedSettingsFilePath() => _resolveSettingsFilePath();

  /// The app-folder location settings used to live in, for the same tests.
  @visibleForTesting
  static String legacySettingsFilePath() => _legacySettingsFilePath();

  /// One-time move of an app-folder app_config.json into the per-user folder.
  /// Only runs when the per-user file doesn't exist yet, so it can never
  /// clobber newer settings, and never deletes the original.
  static void _migrateLegacySettingsFile(String target) {
    try {
      if (File(target).existsSync()) return;
      final legacy = File(_legacySettingsFilePath());
      if (legacy.path == target || !legacy.existsSync()) return;
      Directory(path.dirname(target)).createSync(recursive: true);
      legacy.copySync(target);
      AppLogger.logInfo(
          'Moved app_config.json into the per-user settings folder '
          '($target) so it survives app updates. The old copy at '
          '${legacy.path} is no longer read.');
    } catch (e, stack) {
      AppLogger.logError('Could not migrate the old app_config.json', e, stack);
    }
  }

  /// Everything that goes into app_config.json.
  ///
  /// Deliberately NOT here: the processor password. It is the one stored value
  /// that isn't a setting, so it lives in the OS keystore instead — and leaving
  /// it out of this map is also what strips a plain-text copy written by an
  /// older build, on the next save.
  @visibleForTesting
  Map<String, dynamic> settingsAsJson() => {
      '__readme':
          'Application settings for the Room Config Builder. File paths may '
          'be edited by hand while the app is closed; blank paths fall back '
          'to files in the Root Folder (blank root = the app folder).',
      'initialSetupComplete': _initialSetupComplete,
      'rootFolderPath': rootFolderPath,
      'modulesPath': modulesPath,
      'processorsFilePath': processorsFilePath,
      'buildingsFilePath': buildingsFilePath,
      'templateFilePath': templateFilePath,
      'uiSchemaPath': uiSchemaPath,
      'keyMapPath': keyMapPath,
      'avDevicesFilePath': avDevicesFilePath,
      'flowRulesFilePath': flowRulesFilePath,
      'documentationPath': documentationPath,
      'sftpUsername': sftpUsername,
      'sftpPort': sftpPort,
      'sftpRemoteConfigPath': sftpRemoteConfigPath,
      // defaultProcessorPassword is deliberately absent: it lives in the OS
      // keystore, never in this file. Omitting it here is also what strips a
      // plain-text copy left by an older build.
      'useDefaultProcessorPassword': useDefaultProcessorPassword,
      'isDarkMode': isDarkMode,
      'themeStyle': themeStyle,
      'classicColor': classicColor,
      'aurisColor': aurisColor,
      'classicSecondary': classicSecondary,
      'textScale': textScale,
      'currencySymbol': currencySymbol,
      'pricingTier': pricingTier.name,
      'fillDeviceDefaultsOnLoad': fillDeviceDefaultsOnLoad,
      'confirmBeforeDelete': confirmBeforeDelete,
      'snapDiagramsToGrid': snapDiagramsToGrid,
      'showDiagramGrid': showDiagramGrid,
      'autosaveEnabled': autosaveEnabled,
      'autosaveMinutes': autosaveMinutes,
      'roomScanDepth': roomScanDepth,
    };

  /// Serializes every setting to app_config.json. Failures are logged but
  /// never thrown — a read-only folder must not break the running app.
  Future<void> _persistSettings() async {
    if (!_persistenceEnabled) return; // Test provider: leave the file alone
    if (settingsFilePath.isEmpty) settingsFilePath = _resolveSettingsFilePath();
    final Map<String, dynamic> data = settingsAsJson();
    try {
      const encoder = JsonEncoder.withIndent('    ');
      final file = File(settingsFilePath);
      // The per-user settings folder doesn't exist on a first launch.
      await file.parent.create(recursive: true);
      await file.writeAsString(encoder.convert(data));
    } catch (e, stack) {
      AppLogger.logError(
          'Failed to save settings to $settingsFilePath', e, stack);
    }
  }

  /// One-time import of settings saved by older versions in the OS store
  /// (SharedPreferences). Only runs when no app_config.json exists yet; the
  /// result is written to the file right afterwards. Bounded by a timeout so
  /// a hung OS store can never freeze startup.
  Future<Map<String, dynamic>> _migrateFromSharedPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      final keys = prefs.getKeys();
      if (keys.isEmpty) return {};
      final Map<String, dynamic> saved = {
        for (final key in keys) key: prefs.get(key),
      };
      AppLogger.logInfo(
          'Imported ${saved.length} setting(s) from the OS store into app_config.json.');
      return saved;
    } catch (e) {
      AppLogger.logError('Skipped OS-store settings migration', e);
      return {};
    }
  }

  // ---------------------------------------------------------------------
  //  FIRST-RUN SETUP
  //  On the very first launch (no saved settings yet) the UI shows a
  //  one-time dialog asking where each file is located. Once the user
  //  finishes (or skips) the dialog, 'initialSetupComplete' is persisted
  //  and the check is bypassed on every later launch. The app is fully
  //  usable either way — every path has a working default, so nothing
  //  blocks if no folder is ever selected.
  // ---------------------------------------------------------------------

  /// True while the one-time setup dialog should be shown.
  bool firstRunSetupNeeded = false;

  /// True once _loadSavedSettings has finished reading SharedPreferences,
  /// so the UI doesn't flash the setup dialog before the answer is known.
  bool settingsLoaded = false;

  /// Marks first-run setup as done (persisted), then loads everything from
  /// the chosen/default locations so the app is immediately usable.
  Future<void> completeFirstRunSetup() async {
    firstRunSetupNeeded = false;
    _initialSetupComplete = true;
    await _persistSettings();

    await loadUiSchema();
    await loadKeyMap();
    await loadAvDeviceLibrary();
    await loadFlowRules();
    await loadLaborRates();
    await loadBaseCosts();
    await loadBuildingsList();
    await loadProcessorsList();
    // ignore: unawaited_futures
    preloadAllModules();
    notifyListeners();
    AppLogger.logInfo("First-run setup completed. Paths saved; check bypassed on future launches.");
  }

  /// Lets App Config re-open the setup dialog at any time.
  void requestFirstRunSetup() {
    firstRunSetupNeeded = true;
    notifyListeners();
  }

  // --- UI Schema (drives labels, descriptions, dropdowns for config keys) ---
  // Starts with built-in defaults so the editor works before/without a file.
  UiSchema uiSchema = UiSchema.builtIn();

  // --- Key Map (translates legacy config key names on load) ---
  // Built-in map is empty, so with no key_map.json loading behaves as before.
  ConfigKeyMap keyMap = ConfigKeyMap.builtIn();

  // --- AV device library (connector sets for the AV Flow tab) ---
  // The room config describes control, never AV connectors, so the ports a
  // device shows on the AV canvas come from here. Built-ins cover the common
  // models; av_devices.json in the Root Folder overrides and extends them.
  AvDeviceLibrary avDeviceLibrary = AvDeviceLibrary.builtIn();

  // --- AV flow rules (how a room draws itself from its config) ---
  // Which box each input_/output_ key means, what goes between two ends that
  // do not take the same cable, and what hangs off a USB switcher. Built-in
  // defaults reproduce what used to be constants in av_flow_routing.dart;
  // av_flow_rules.json in the Root Folder overrides them, and the Flow Rules
  // tab writes that file.
  FlowRules flowRules = FlowRules.builtIn();

  // --- Labor rates (what an hour costs, per job type) ---
  // Shared across rooms so revising a rate re-costs every estimate that uses
  // it. Read from labor_rates.json in the Root Folder; the built-in roles
  // (CTS III / CTS IV / TSRV / FMS) stand in until that file exists.
  LaborRateBook laborRates = LaborRateBook.builtIn();

  // --- Base costs (what a switcher costs before you pick a switcher) ---
  // The coarse rate card the estimate falls back to when a device on the
  // diagram has no model, or has one the catalog doesn't price. Read from
  // base_costs.json in the Root Folder; ships with every figure unset.
  BaseCostBook baseCosts = BaseCostBook.builtIn();

  /// The active working file on disk: the file opened locally, or the working
  /// copy chosen during an SFTP download. Empty when the session started from
  /// 'Create New' and hasn't been saved anywhere yet.
  String currentConfigPath = '';
  
  // --- Data State ---
  List<dynamic> processors = [];
  Map<String, dynamic> buildings = {}; // NEW: Store building abbreviations
  Map<String, dynamic>? selectedProcessor;

  Map<String, dynamic> _roomConfig = {};

  /// The loaded room, as blocks of properties.
  ///
  /// Every block is stored as a `Map<String, dynamic>` whatever the caller
  /// hands over — see [_openConfigMaps]. That is not tidiness: a block that
  /// arrives as a `Map<String, String>` (a converted device whose values all
  /// happened to be strings, a block built by a `{for ...}` literal) throws
  /// `type 'int' is not a subtype of type 'String'` the moment somebody types
  /// a baud rate into it, from inside a text field's onChanged where nothing
  /// reports it: the digit simply never lands, and the field looks broken.
  Map<String, dynamic> get roomConfig => _roomConfig;

  set roomConfig(Map<String, dynamic> value) {
    _roomConfig = _openConfigMaps(value) as Map<String, dynamic>;
  }

  /// [value] with every nested map re-typed as `Map<String, dynamic>` and
  /// every list as `List<dynamic>`, so any value can later be written into it.
  ///
  /// Applied on the way IN rather than defended against at each of the write
  /// sites, because there are half a dozen of those and one of them will
  /// always be the one somebody forgets.
  static dynamic _openConfigMaps(dynamic value) {
    if (value is Map) {
      return <String, dynamic>{
        for (final e in value.entries)
          e.key.toString(): _openConfigMaps(e.value),
      };
    }
    if (value is List) return [for (final v in value) _openConfigMaps(v)];
    return value;
  }

  /// Bumped every time [roomConfig] is REPLACED wholesale — New from template,
  /// opening a file, an SFTP download, Apply Changes in the raw editor, Use
  /// Original. The views key their content on it so Flutter throws the old
  /// input elements away instead of reusing them: `TextFormField.initialValue`
  /// and `Autocomplete.initialValue` are read once per element, so without a
  /// changing key the previous room's name/number sat on the Wizard until the
  /// tab was switched away and back.
  int configRevision = 0;

  /// Call after any wholesale replacement of [roomConfig]. Callers still
  /// notifyListeners() themselves — this only moves the identity forward.
  void _bumpConfigRevision() => configRevision++;

  bool isDarkMode = true;

  /// Visual style selected in App Config. 'classic' (the default) is a
  /// Material theme built with flex_color_scheme around [classicColor];
  /// 'auris' is the sci-fi HUD look built around [aurisColor]. Dark/light
  /// stays a separate toggle that works with every style.
  String themeStyle = 'classic';

  /// Accent color for the Classic theme, stored as a 6-digit RRGGBB hex
  /// string. Chosen from the color picker in App Config (or the first-run
  /// setup dialog). Default: Material blue.
  String classicColor = '2196F3';

  /// Accent color for the Auris theme (RRGGBB hex), chosen from its own
  /// swatch picker in App Config. Default: the package's canonical amber.
  String aurisColor = 'F0A500';

  /// Secondary element color for the Classic style (RRGGBB hex, or '' =
  /// Auto — let the theme derive it). Feeds into flex_color_scheme and
  /// colors the navigation highlight, chips, and toggles. (Auris bakes its
  /// own slate secondary, so it has no counterpart setting.)
  String classicSecondary = '';

  /// App-wide text scale factor (1.0 = normal). Chosen from the Text Size
  /// dropdown in App Config and applied to every view via a MediaQuery
  /// text scaler around the whole MaterialApp.
  double textScale = 1.0;

  /// What goes in front of every figure the app prints. One app-wide answer
  /// rather than one per room: a shop bills in one currency, and re-typing the
  /// symbol per estimate is how two quotes for the same building end up
  /// reading differently.
  String currencySymbol = r'$';

  /// Which of a catalog entry's two prices the estimates use. See
  /// [PricingTier]; app-wide for the same reason as the symbol, and switchable
  /// per estimate run rather than per device.
  PricingTier pricingTier = PricingTier.msrp;

  void setPricingTier(PricingTier tier) {
    if (pricingTier == tier) return;
    pricingTier = tier;
    notifyListeners();
    // ignore: unawaited_futures
    _persistSettings();
  }

  /// When true (default), loading a config also fills any device properties
  /// missing from the schema's "device_defaults" (e.g. a DSP without its
  /// audio group numbers). Additions are listed in the acknowledgement
  /// dialog and change log like every other load-time migration. Toggle
  /// lives in App Config.
  bool fillDeviceDefaultsOnLoad = true;

  Future<void> setFillDeviceDefaultsOnLoad(bool value) async {
    fillDeviceDefaultsOnLoad = value;
    notifyListeners();
    await _persistSettings();
  }

  /// When true (default), the trash buttons on the Devices/System tabs ask
  /// for confirmation before removing a property. Toggle lives in App Config
  /// for users who prefer one-click deletes.
  bool confirmBeforeDelete = true;

  Future<void> setConfirmBeforeDelete(bool value) async {
    confirmBeforeDelete = value;
    notifyListeners();
    await _persistSettings();
  }

  /// When true, a box dragged on the AV Flow, Control Schematic or Cabling
  /// drawing lands on the [kDiagramGridStep] grid instead of exactly where the
  /// mouse let go.
  ///
  /// One setting for all three pages rather than a toggle per tab: it is a way
  /// of working, not a property of a drawing, and somebody who wants their
  /// boxes lined up wants them lined up everywhere. Remembered in
  /// app_config.json for the same reason — being asked again every launch is
  /// how a preference becomes a nuisance.
  ///
  /// Off by default: it changes where a drop lands, and a drawing somebody has
  /// already placed by hand should not start moving under them after an update.
  bool snapDiagramsToGrid = false;

  Future<void> setSnapDiagramsToGrid(bool value) async {
    snapDiagramsToGrid = value;
    notifyListeners();
    await _persistSettings();
  }

  /// Whether the alignment grid is drawn behind the three diagrams.
  ///
  /// Separate from [snapDiagramsToGrid] because they answer different
  /// questions: one is where a box lands, the other is whether the paper has
  /// squares on it. Somebody laying out a busy sheet wants to see the lines
  /// without having their placements moved; somebody who trusts the snap wants
  /// the squares gone.
  ///
  /// On screen only — it is never in an export; see `diagram_grid.dart`.
  bool showDiagramGrid = true;

  Future<void> setShowDiagramGrid(bool value) async {
    showDiagramGrid = value;
    notifyListeners();
    await _persistSettings();
  }

  // --- Finding rooms on a share --------------------------------------------

  /// How many folders down "Find rooms in a folder…" looks for room configs.
  ///
  /// Two is the layout this app writes: a room's files loose in one folder, or
  /// a folder per room inside a folder for the building. It is NOT the only
  /// layout a share has — a processor export lands as
  /// `BSS 101/code/upload_to_root/config.json`, which is four down, and a
  /// scan that stops at two finds none of it.
  ///
  /// A setting rather than "just go deeper by default" because depth is the
  /// only thing separating a room from a backup of one: the further down this
  /// goes, the more old revisions and archive copies come back with the real
  /// rooms, and a room added twice doubles its cost on the quote. Somebody who
  /// knows their share is nested sets it once; everybody else keeps the
  /// shallow scan that cannot pick up a copy.
  int roomScanDepth = kDefaultRoomScanDepth;

  /// The depths the App Config dropdown offers.
  static const List<int> kRoomScanDepths = [1, 2, 3, 4, 5, 6];

  /// What a scan looks under when nobody has changed it.
  static const int kDefaultRoomScanDepth = 2;

  static int _sanitizeRoomScanDepth(dynamic raw) {
    final n = raw is int
        ? raw
        : (int.tryParse(raw?.toString() ?? '') ?? kDefaultRoomScanDepth);
    return n < 1 ? 1 : (n > 8 ? 8 : n);
  }

  Future<void> setRoomScanDepth(int value) async {
    final depth = _sanitizeRoomScanDepth(value);
    if (depth == roomScanDepth) return;
    roomScanDepth = depth;
    notifyListeners();
    await _persistSettings();
  }

  // --- Autosave ------------------------------------------------------------

  /// Whether the recovery snapshots run on a timer. On by default: the work
  /// this app holds — a room's config, four drawings, an estimate and the
  /// project around them — is hours of it, and the cost of a snapshot nobody
  /// ever reads is a few files in a folder nobody ever opens.
  bool autosaveEnabled = true;

  /// How often a snapshot is taken, in minutes. See [kAutosaveIntervals] for
  /// what the App Config dropdown offers.
  int autosaveMinutes = 5;

  Future<void> setAutosaveEnabled(bool value) async {
    autosaveEnabled = value;
    _restartAutosaveTimer();
    notifyListeners();
    await _persistSettings();
  }

  Future<void> setAutosaveMinutes(int value) async {
    if (value <= 0) return;
    autosaveMinutes = value;
    _restartAutosaveTimer();
    notifyListeners();
    await _persistSettings();
  }

  /// True when the LAST load actually changed or flagged anything (key
  /// mapping, migrations, defaults, audits). The acknowledgement dialog only
  /// appears when this is set — a clean re-load of an already-migrated file
  /// stays silent.
  bool lastLoadHadChanges = false;

  /// True once the user has dealt with that conversion — read the log and
  /// acknowledged it, or been through the preview and applied their choices.
  ///
  /// Separate from [lastLoadHadChanges] because the two answer different
  /// questions. "Did this file need converting?" stays true for the session,
  /// and keeps the log reachable from the toolbar. "Is there anything still
  /// wanting attention?" is what the red count on the button is for, and a
  /// count that stays up after the work is done stops meaning anything.
  ///
  /// Reset by the next load, so reopening a file that still needs converting
  /// lights the count again.
  bool conversionAcknowledged = false;

  /// Whether the toolbar's Convert button should still be showing its count.
  bool get conversionNeedsAttention =>
      lastLoadHadChanges && !conversionAcknowledged;

  /// Marks the conversion as dealt with and repaints the toolbar. Called when
  /// the acknowledgement dialog is closed or the preview's choices are
  /// applied; both mean the same thing to the button.
  void acknowledgeConversion() {
    if (conversionAcknowledged) return;
    conversionAcknowledged = true;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  //  CONVERSION PROVENANCE
  //  Filled at the end of every load: where each value in the working config
  //  came from, and the reversible list of what the conversion did. The
  //  preview panel and the field editors both read these; both are cleared
  //  when a config is created from the template rather than converted.
  // ---------------------------------------------------------------------

  /// 'SECTION.key' -> where that value came from. A key absent from the map
  /// has no conversion history (a config built from the template, or a value
  /// the user has since typed) and is drawn in the normal text color.
  final Map<String, ValueOrigin> valueOrigins = {};

  /// Every reversible change the last conversion made, in section/key order.
  final List<ConversionChange> conversionChanges = [];

  /// True when the last load actually converted something, i.e. the preview
  /// has something to show.
  bool get hasConversionPreview => conversionChanges.isNotEmpty;

  /// The deep copy of the file as it was parsed, before any conversion step.
  /// Used to diff against and to restore individual rejected changes.
  Map<String, dynamic> _originalLoadedConfig = {};

  /// Loaded-file section name -> what the conversion renamed it to
  /// ('CAMERA1DEVICE' -> 'CAMERADEVICE_1'), from the last load.
  Map<String, String> lastSectionRenames = const {};

  /// The block [sectionKey] came from in the pre-conversion file, or null when
  /// the original has nothing under that name.
  ///
  /// Tries the section's own name first, then the name it was renamed FROM, so
  /// a legacy `CAMERA1DEVICE` still answers for `CAMERADEVICE_1`.
  Map<String, dynamic>? originalBlockFor(String sectionKey) {
    dynamic block = _originalLoadedConfig[sectionKey];
    if (block is! Map) {
      for (final entry in lastSectionRenames.entries) {
        if (entry.value != sectionKey) continue;
        block = _originalLoadedConfig[entry.key];
        break;
      }
    }
    if (block is! Map) return null;
    return {
      for (final e in block.entries) e.key.toString(): e.value,
    };
  }

  ValueOrigin? originFor(String sectionKey, String fieldKey) =>
      valueOrigins['$sectionKey.$fieldKey'];

  /// Drops the conversion color from a value the USER has just set.
  ///
  /// The map records what the LOAD did to each value, and orange reads as
  /// "carried over from the old file, nobody has checked it against the
  /// current template yet". The moment a tech types the value themselves that
  /// is no longer true of it, so the field falls back to the theme's ordinary
  /// color — which is what a value with no conversion history looks like.
  /// Every write the user drives goes through here; the load-time migrations
  /// deliberately do not, since coloring what they changed is the point.
  void _forgetConversionOrigin(String sectionKey, String key) {
    valueOrigins.remove('$sectionKey.$key');
  }

  /// Seeds the "file as parsed" side of the diff, so a test can drive
  /// [computeConversionProvenance] without a real load.
  @visibleForTesting
  set originalLoadedConfig(Map<String, dynamic> value) =>
      _originalLoadedConfig = value;

  /// The file as it was parsed, before any conversion step — read-only.
  ///
  /// Empty when this session never loaded a legacy file. See
  /// [ensureOriginalFileConfig], which fills it from the `_old_config.json`
  /// backup beside the working file when the room was converted in an earlier
  /// session and re-opened in this one.
  Map<String, dynamic> get originalLoadedConfig => _originalLoadedConfig;

  /// True when there is an original, pre-conversion copy of this room to
  /// compare a device block against — in memory, or on disk beside the config.
  bool get hasOriginalFileConfig =>
      _originalLoadedConfig.isNotEmpty || originalConfigBackupPath.isNotEmpty;

  /// The `*_old_config.json` this room's conversion left in the config's own
  /// folder, or '' when there is none.
  ///
  /// The backup is written by [_processLoadedConfig] on every load of a file
  /// that needed converting, and it is the ONLY record of what the room said
  /// before the app touched it once the session that converted it has gone.
  /// Found by name rather than remembered, so re-opening the room next month
  /// still finds it.
  String get originalConfigBackupPath {
    if (currentConfigPath.isEmpty) return '';
    try {
      final dir = Directory(path.dirname(currentConfigPath));
      if (!dir.existsSync()) return '';
      final stem = path
          .basenameWithoutExtension(currentConfigPath)
          .toLowerCase();
      String fallback = '';
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = path.basename(entity.path).toLowerCase();
        if (!name.endsWith('_old_config.json')) continue;
        // The one named for THIS room wins over any other conversion that
        // happens to be sitting in the same folder.
        final base = name.substring(0, name.length - '_old_config.json'.length);
        if (stem.contains(base) || base.contains(stem)) return entity.path;
        if (fallback.isEmpty) fallback = entity.path;
      }
      return fallback;
    } catch (e) {
      AppLogger.logError('Could not look for an original config backup', e);
      return '';
    }
  }

  /// Reads the on-disk `_old_config.json` into [originalLoadedConfig] when the
  /// session has no in-memory copy. Returns true when there is one to compare
  /// against afterwards.
  ///
  /// Called before the driver-defaults review opens, so its "Original File"
  /// comparison works on a room that was converted and saved days ago.
  Future<bool> ensureOriginalFileConfig() async {
    if (_originalLoadedConfig.isNotEmpty) return true;
    final backup = originalConfigBackupPath;
    if (backup.isEmpty) return false;
    try {
      final parsed = jsonDecode(await File(backup).readAsString());
      if (parsed is! Map) return false;
      _originalLoadedConfig = Map<String, dynamic>.from(parsed);
      AppLogger.logInfo('Loaded the pre-conversion copy from $backup');
      return _originalLoadedConfig.isNotEmpty;
    } catch (e, stack) {
      AppLogger.logError('Could not read the original config backup', e, stack);
      return false;
    }
  }

  /// Drops the coloring and the preview — for a config that wasn't converted
  /// (built from the template, or reloaded as-is).
  void _clearConversionProvenance() {
    valueOrigins.clear();
    conversionChanges.clear();
    _originalLoadedConfig = {};
    // The renames describe which of the OLD file's sections became which of
    // this one's. With no old file there is nothing for them to line up, and
    // leaving them would let the next diff match this room's blocks against
    // the previous room's names.
    lastSectionRenames = const {};
  }

  /// Applies the accept/reject choices from the preview: every REJECTED
  /// change is undone against the working config, and the provenance map is
  /// rebuilt so the tabs recolor to match. Accepted changes stay as they are.
  void applyConversionChoices() {
    for (final change in conversionChanges) {
      if (change.accepted) continue;
      // An empty key is a scalar sitting at the root of the file rather than a
      // property inside a block, so the whole entry is what gets put back or
      // taken away.
      if (change.key.isEmpty) {
        switch (change.kind) {
          case ConversionKind.added:
            roomConfig.remove(change.section);
            valueOrigins.remove(change.id);
            break;
          case ConversionKind.removed:
          case ConversionKind.changed:
            roomConfig[change.section] = change.before;
            valueOrigins[change.id] = ValueOrigin.legacy;
            break;
        }
        continue;
      }
      final section = roomConfig[change.section];
      switch (change.kind) {
        case ConversionKind.added:
          if (section is Map) section.remove(change.key);
          valueOrigins.remove(change.id);
          break;
        case ConversionKind.removed:
        case ConversionKind.changed:
          // Put the loaded file's value back; recreate the block if the whole
          // section was dropped, so rejecting never silently does nothing.
          if (section is Map) {
            section[change.key] = change.before;
          } else {
            roomConfig[change.section] = <String, dynamic>{
              change.key: change.before,
            };
          }
          valueOrigins[change.id] = ValueOrigin.legacy;
          break;
      }
    }
    notifyListeners();
  }

  /// The "deny" path of the acknowledgement dialog: throws away every load-
  /// time change (key mapping, migrations, injected defaults) and reloads the
  /// working file EXACTLY as it sits on disk. The disk file was never
  /// touched by the load, so re-reading it restores the original.
  Future<bool> revertToOriginalLoad() async {
    if (currentConfigPath.isEmpty) return false;
    try {
      final contents = await File(currentConfigPath).readAsString();
      roomConfig = jsonDecode(contents);
      systemLogs.clear();
      lastLoadHadChanges = false;
      conversionAcknowledged = false;
      // Nothing was converted, so there is no provenance to color by
      _clearConversionProvenance();
      _bumpConfigRevision(); // Every field now shows the on-disk value
      _preloadModulesFromConfig();
      notifyListeners();
      AppLogger.logInfo(
          "Load changes discarded - reloaded original file $currentConfigPath");
      return true;
    } catch (e, stack) {
      AppLogger.logError(
          "Failed to reload original file $currentConfigPath", e, stack);
      return false;
    }
  }

  /// The navigation rail tab currently shown, as an [AppTab] index.
  /// Lives in the provider — above the MaterialApp — so it survives the full
  /// remount that switching between the Auris and Classic theme families
  /// forces (see the MaterialApp key in main.dart). Session-only by design.
  ///
  /// COST, NOT PROJECT, on a cold start. The Project tab works with no room
  /// open — that is the point of it — so starting there meant the app opened
  /// on an empty job list, and the start screen with "start a new project" and
  /// "open a file" on it never appeared at all. Landing on a tab that DOES
  /// need a room is what puts those four buttons in front of somebody who has
  /// just double-clicked the icon. The Project button in the banner is one
  /// click away for anybody who wants the job list instead.
  int selectedTabIndex = AppTab.cost.index;

  void selectTab(int index) {
    // WHERE THE ROOM WORK WAS. Closing a job puts the user back in room mode,
    // and "back" has to mean the tab they were actually on rather than a tab
    // the app picked - somebody who closed a project from the middle of
    // cabling a room should land in cabling.
    if (index != AppTab.project.index &&
        index >= 0 &&
        index < AppTab.values.length) {
      _lastRoomTabIndex = index;
    }
    selectedTabIndex = index;
    notifyListeners();
  }

  /// The last tab that was not the Project tab — where [closeProject] hands
  /// the session back to. Starts at the tab a cold session opens on.
  int get lastRoomTabIndex => _lastRoomTabIndex;
  int _lastRoomTabIndex = AppTab.cost.index;

  // ---------------------------------------------------------------------
  //  SCHEMATIC TAB STATE
  //  Node positions dragged in edit mode and user-drawn connection lines.
  //  Held here (not in the view) so edits survive tab switches; persisted
  //  on demand to a sidecar file next to the working config
  //  ("<config>_control_schematic.json") via saveSchematicLayout, and
  //  re-loaded as
  //  soon as that config is opened (the saved diagram belongs to the file, so
  //  it comes back with it). When the session already has a diagram of its
  //  own, the UI asks first — see schematicLayoutNeedsChoice.
  // ---------------------------------------------------------------------

  /// Node id (device key / [kSchematicProcessor] / [kSchematicIdf] /
  /// [kSchematicTouchPanel]) -> position override. Nodes absent from the map
  /// sit at their auto-layout spot.
  final Map<String, Offset> schematicPositions = {};

  /// User-drawn lines: {'from': id, 'to': id, 'color': 'RRGGBB', 'label': s}.
  final List<Map<String, String>> schematicLinks = [];

  /// Auto-generated lines the user has deleted or re-routed, identified as
  /// "fromId>toId". Filtered out of the diagram; restorable from the edit
  /// panel. Persisted in the sidecar with the rest of the layout.
  final Set<String> schematicHiddenEdges = {};

  /// Boxes the user added by hand: equipment that is part of the room but not
  /// part of the control system — the building network switch the processor
  /// lands on, a UPS, a room PC, a wall plate, somebody else's rack.
  ///
  /// The diagram is DERIVED from the config, so anything the config does not
  /// know about could not be drawn at all: the reader was left to infer that
  /// the network line disappears into a switch that exists. These are the
  /// exception — the user's own boxes, drawn as related equipment rather than
  /// as controlled devices, and linkable with the ordinary line tool.
  ///
  /// {'id': 'EXTRA_1', 'title': s, 'subtitle': s, 'icon': key}. Same shape as
  /// [schematicLinks] (plain strings) so the sidecar stays a flat document.
  final List<Map<String, String>> schematicExtraNodes = [];

  /// Where the room's AV LAN devices land on the control schematic.
  ///
  /// A device whose `ip_address` starts with 192. is not on the building
  /// network — it is on the AV LAN, which in most of these rooms is the
  /// processor's own second NIC and in some is a small switch of its own. The
  /// drawing used to run every network device to the IDF regardless, which is
  /// the one thing about the room's networking somebody actually needs the
  /// drawing to tell them, said wrong.
  ///
  /// Which of the three it is varies by building and cannot be read off the
  /// config, so it is a choice the room records: 'IDF', 'PROCESSOR', or the id
  /// of a box added by hand ([schematicExtraNodes]).
  String schematicAvLanTarget = kSchematicIdf;

  /// Where the touch panel lands, same three answers. Separate from
  /// [schematicAvLanTarget] because it is a separate decision: a panel on PoE
  /// off the building switch is as ordinary as one on the AV LAN beside the
  /// processor, and a room can be built either way whatever its devices do.
  String schematicPanelTarget = kSchematicIdf;

  /// True when either landing choice is anything but the default.
  bool get _schematicLandingsMoved =>
      schematicAvLanTarget != kSchematicIdf ||
      schematicPanelTarget != kSchematicIdf;

  /// Records where one group of drops lands. [avLan] false sets the panel's.
  void setSchematicLanding(String target, {required bool avLan}) {
    final clean = target.trim().isEmpty ? kSchematicIdf : target.trim();
    if ((avLan ? schematicAvLanTarget : schematicPanelTarget) == clean) return;
    _pushSchematicUndo(avLan ? 'AV LAN drops' : 'Touch panel drop');
    if (avLan) {
      schematicAvLanTarget = clean;
    } else {
      schematicPanelTarget = clean;
    }
    notifyListeners();
  }

  /// Ids [SchematicModel] would generate itself, which a hand-added box must
  /// never collide with — it would silently take a real device's place in the
  /// links and the positions.
  static const Set<String> _kSchematicReservedIds = {
    kSchematicProcessor,
    kSchematicIdf,
    'TOUCHPANEL',
  };

  /// Per-room overrides of the control schematic's line colors, keyed by
  /// the connection category's index in ConnType. Stored by index because
  /// this layer must not depend on the view that defines the enum. Empty
  /// means the built-in colors.
  final Map<int, Color> schematicConnColors = {};

  /// The color a connection category is drawn in for this room.
  Color schematicConnColor(int connIndex, Color fallback) =>
      schematicConnColors[connIndex] ?? fallback;

  void setSchematicConnColor(int connIndex, Color? color) {
    _pushSchematicUndo('Line color');
    if (color == null) {
      schematicConnColors.remove(connIndex);
    } else {
      schematicConnColors[connIndex] = color;
    }
    notifyListeners();
  }

  void resetSchematicConnColors() {
    schematicConnColors.clear();
    notifyListeners();
  }

  /// The config path the schematic state currently belongs to, so switching
  /// configs resets the layout instead of carrying stale node spots over.
  String _schematicSyncedPath = ' never';

  // --- undo (control schematic) -------------------------------------------
  //  The layout is four small collections, so a snapshot is a handful of
  //  copies — no need for the JSON round-trip the AV document uses.

  final List<({String label, Map<String, Offset> positions,
      List<Map<String, String>> links, Set<String> hidden,
      Map<int, Color> colors, List<Map<String, String>> extras,
      String avLan, String panel})>
      _schematicUndoStack = [];

  bool get canUndoSchematic => _schematicUndoStack.isNotEmpty;

  String get schematicUndoLabel =>
      _schematicUndoStack.isEmpty ? '' : _schematicUndoStack.last.label;

  /// Records the layout BEFORE [label] happens.
  void _pushSchematicUndo(String label) {
    _schematicUndoStack.add((
      label: label,
      positions: Map<String, Offset>.from(schematicPositions),
      links: [for (final l in schematicLinks) Map<String, String>.from(l)],
      hidden: Set<String>.from(schematicHiddenEdges),
      colors: Map<int, Color>.from(schematicConnColors),
      extras: [
        for (final n in schematicExtraNodes) Map<String, String>.from(n),
      ],
      avLan: schematicAvLanTarget,
      panel: schematicPanelTarget,
    ));
    if (_schematicUndoStack.length > _kMaxUndoDepth) {
      _schematicUndoStack.removeAt(0);
    }
  }

  /// Puts the layout back the way it was before the last edit. Returns what
  /// was undone, or '' when there was nothing on the stack.
  String undoSchematic() {
    if (_schematicUndoStack.isEmpty) return '';
    final entry = _schematicUndoStack.removeLast();
    schematicPositions
      ..clear()
      ..addAll(entry.positions);
    schematicLinks
      ..clear()
      ..addAll(entry.links);
    schematicHiddenEdges
      ..clear()
      ..addAll(entry.hidden);
    schematicConnColors
      ..clear()
      ..addAll(entry.colors);
    schematicExtraNodes
      ..clear()
      ..addAll(entry.extras);
    schematicAvLanTarget = entry.avLan;
    schematicPanelTarget = entry.panel;
    AppLogger.logInfo('Undid: ${entry.label}');
    notifyListeners();
    return entry.label;
  }

  void setSchematicPosition(String nodeId, Offset pos) {
    // Called once, on release: the drag itself is previewed in the view.
    _pushSchematicUndo('Move node');
    schematicPositions[nodeId] = pos;
    notifyListeners();
  }

  void addSchematicLink(String from, String to, String colorHex, String label) {
    _pushSchematicUndo('Draw line');
    schematicLinks.add(
        {'from': from, 'to': to, 'color': colorHex, 'label': label});
    notifyListeners();
  }

  void removeSchematicLinkAt(int index) {
    if (index < 0 || index >= schematicLinks.length) return;
    _pushSchematicUndo('Remove line');
    schematicLinks.removeAt(index);
    notifyListeners();
  }

  /// Rewrites a user-drawn line in place (the edit-line dialog).
  void updateSchematicLinkAt(
      int index, String from, String to, String colorHex, String label) {
    if (index < 0 || index >= schematicLinks.length) return;
    _pushSchematicUndo('Edit line');
    schematicLinks[index] =
        {'from': from, 'to': to, 'color': colorHex, 'label': label};
    notifyListeners();
  }

  // --- hand-added boxes ------------------------------------------------------

  /// Adds a box for equipment the control system does not talk to. Returns the
  /// id it was filed under, so the caller can select or position it.
  ///
  /// [title] is required in spirit — a nameless box on a drawing is noise — so
  /// a blank one is refused rather than drawn.
  String addSchematicExtraNode({
    required String title,
    String subtitle = '',
    String icon = '',
  }) {
    if (title.trim().isEmpty) return '';
    _pushSchematicUndo('Add related device');
    final taken = {
      ..._kSchematicReservedIds,
      for (final n in schematicExtraNodes) n['id'] ?? '',
    };
    var n = schematicExtraNodes.length + 1;
    while (taken.contains('EXTRA_$n')) {
      n++;
    }
    final id = 'EXTRA_$n';
    schematicExtraNodes.add({
      'id': id,
      'title': title.trim(),
      'subtitle': subtitle.trim(),
      'icon': icon.trim(),
    });
    notifyListeners();
    return id;
  }

  void updateSchematicExtraNodeAt(
    int index, {
    required String title,
    String subtitle = '',
    String icon = '',
  }) {
    if (index < 0 || index >= schematicExtraNodes.length) return;
    if (title.trim().isEmpty) return;
    _pushSchematicUndo('Edit related device');
    schematicExtraNodes[index] = {
      // The id is the box's identity on every line drawn to it, so an edit
      // keeps it. Renaming through a new id would orphan the lines.
      'id': schematicExtraNodes[index]['id'] ?? '',
      'title': title.trim(),
      'subtitle': subtitle.trim(),
      'icon': icon.trim(),
    };
    notifyListeners();
  }

  /// Removes a hand-added box, and with it the lines drawn to it and the spot
  /// it was dragged to. [SchematicModel] already declines to draw a line whose
  /// endpoint is gone, but leaving the entries behind means a later box that
  /// reused the id would inherit somebody else's lines.
  void removeSchematicExtraNodeAt(int index) {
    if (index < 0 || index >= schematicExtraNodes.length) return;
    _pushSchematicUndo('Remove related device');
    final id = schematicExtraNodes.removeAt(index)['id'] ?? '';
    if (id.isNotEmpty) {
      schematicLinks.removeWhere((l) => l['from'] == id || l['to'] == id);
      schematicPositions.remove(id);
    }
    notifyListeners();
  }

  void hideSchematicEdge(String edgeId) {
    _pushSchematicUndo('Hide connection');
    schematicHiddenEdges.add(edgeId);
    notifyListeners();
  }

  void restoreSchematicEdge(String edgeId) {
    _pushSchematicUndo('Restore connection');
    schematicHiddenEdges.remove(edgeId);
    notifyListeners();
  }

  /// Clears dragged positions (auto-layout takes over again). Custom lines
  /// are kept — they are removed individually from the edit panel.
  /// Throws away everything the control schematic carries that the config did
  /// not put there — dragged positions, hand-drawn lines, auto lines somebody
  /// hid, and boxes added by hand — so the next build is the drawing the
  /// config describes and nothing else.
  ///
  /// The line COLORS stay. They are a per-room choice with its own **Reset
  /// all** on the Colors dialog, and a recolored legend does not contradict
  /// the config. A landing choice ([schematicAvLanTarget],
  /// [schematicPanelTarget]) stays too — where the room's drops actually go is
  /// a fact somebody recorded, not drawing that has drifted — unless it points
  /// at one of the hand-added boxes being removed, which would leave the drops
  /// landing on nothing.
  void recreateSchematicFromConfig() {
    _pushSchematicUndo('Recreate from config');
    schematicPositions.clear();
    schematicLinks.clear();
    schematicHiddenEdges.clear();
    final removed = {for (final n in schematicExtraNodes) n['id'] ?? ''};
    schematicExtraNodes.clear();
    if (removed.contains(schematicAvLanTarget)) {
      schematicAvLanTarget = kSchematicIdf;
    }
    if (removed.contains(schematicPanelTarget)) {
      schematicPanelTarget = kSchematicIdf;
    }
    notifyListeners();
  }

  void resetSchematicPositions() {
    _pushSchematicUndo('Reset layout');
    schematicPositions.clear();
    notifyListeners();
  }

  /// Sidecar file the layout persists to ('' when the session has no working
  /// file yet — Create New that was never saved).
  String get schematicSidecarPath {
    if (currentConfigPath.isEmpty) return '';
    final dir = path.dirname(currentConfigPath);
    final base = path.basenameWithoutExtension(currentConfigPath);
    return path.join(dir, '${base}_control_schematic.json');
  }

  /// The name this sidecar used before the tab was renamed to Control
  /// Schematic. Rooms documented with an older build still have one of these
  /// sitting next to the config, so it is read when the new name is absent
  /// and removed once the layout has been written under the new name — see
  /// [loadSchematicLayoutForCurrentConfig] and [saveSchematicLayout].
  String get legacySchematicSidecarPath {
    if (currentConfigPath.isEmpty) return '';
    final dir = path.dirname(currentConfigPath);
    final base = path.basenameWithoutExtension(currentConfigPath);
    return path.join(dir, '${base}_schematic.json');
  }

  /// Where the layout should actually be READ from: the current name when it
  /// exists, otherwise the old one. Empty when neither is there.
  String get _readableSchematicSidecar {
    final current = schematicSidecarPath;
    if (current.isNotEmpty && File(current).existsSync()) return current;
    final legacy = legacySchematicSidecarPath;
    if (legacy.isNotEmpty && File(legacy).existsSync()) return legacy;
    return '';
  }

  /// True when the in-memory diagram holds anything the user arranged by hand
  /// (dragged nodes, drawn lines, deleted auto-edges). Drives the "keep or
  /// replace" prompt when a config with its own saved layout is opened.
  bool get hasSchematicLayout =>
      schematicPositions.isNotEmpty ||
      schematicLinks.isNotEmpty ||
      schematicHiddenEdges.isNotEmpty ||
      schematicConnColors.isNotEmpty ||
      schematicExtraNodes.isNotEmpty ||
      _schematicLandingsMoved;

  /// True when a saved control schematic sits next to the working config,
  /// under either the current name or the pre-rename one.
  bool get hasSavedSchematicLayout => _readableSchematicSidecar.isNotEmpty;

  /// True when the config that was just opened needs the user's call on the
  /// diagram: they arranged one in this session AND the file has its own saved
  /// layout beside it. Without both, loading the sidecar (or clearing) is the
  /// obvious answer and happens without a prompt.
  bool get schematicLayoutNeedsChoice =>
      _schematicSyncedPath != currentConfigPath &&
      hasSchematicLayout &&
      hasSavedSchematicLayout;

  /// Empties the in-memory diagram and detaches it from any file, so the next
  /// Schematic tab visit starts from the auto-layout.
  void _resetSchematicLayout() {
    _schematicSyncedPath = currentConfigPath;
    // A different room's edits are not this room's to undo.
    _schematicUndoStack.clear();
    schematicPositions.clear();
    schematicLinks.clear();
    schematicHiddenEdges.clear();
    schematicConnColors.clear();
    schematicExtraNodes.clear();
    schematicAvLanTarget = kSchematicIdf;
    schematicPanelTarget = kSchematicIdf;
  }

  /// Adopts the CURRENT in-memory diagram for the working config, ignoring any
  /// saved sidecar next to it — the "discard the saved schematic" answer to the
  /// prompt shown on load. Nothing is written; the sidecar on disk is only
  /// replaced if the user later hits Save Layout.
  void keepSchematicLayoutForCurrentConfig() {
    _schematicSyncedPath = currentConfigPath;
    AppLogger.logInfo(
        'Kept the in-memory schematic layout; the saved layout beside '
        '$currentConfigPath was not loaded.');
    notifyListeners();
  }

  /// Called when the Schematic tab opens: if the working config changed since
  /// the last visit, drop the old layout and load the sidecar if one exists.
  void ensureSchematicLayoutForCurrentConfig() {
    if (_schematicSyncedPath == currentConfigPath) return;
    loadSchematicLayoutForCurrentConfig();
  }

  /// Replaces the in-memory diagram with the layout saved beside the working
  /// config (blank when there is no sidecar). Called unconditionally when a
  /// config is opened — the saved schematic belongs to the file, so it comes
  /// back with it — and lazily by the Schematic tab for older sessions.
  void loadSchematicLayoutForCurrentConfig() {
    _resetSchematicLayout();
    // Notify in every path — the tab has already built by the time this runs
    // (post-frame), so without it a loaded sidecar wouldn't show until the
    // next unrelated rebuild.
    // Reads whichever name is actually on disk, so a room documented before
    // the rename opens untouched. Nothing is moved here — a read should not
    // rewrite the user's folder; the file moves on the next save.
    final sidecar = _readableSchematicSidecar;
    if (sidecar.isEmpty) {
      notifyListeners();
      return;
    }
    try {
      final doc = jsonDecode(File(sidecar).readAsStringSync());
      if (doc is! Map) {
        notifyListeners();
        return;
      }
      _readSchematicJson(Map<String, dynamic>.from(doc));
      AppLogger.logInfo(
          'Control schematic loaded from $sidecar '
          '(${schematicPositions.length} positions, '
          '${schematicLinks.length} lines)'
          '${sidecar == legacySchematicSidecarPath ? ' — pre-rename file; it '
              'moves to ${path.basename(schematicSidecarPath)} on the next '
              'Save Layout.' : '.'}');
    } catch (e) {
      AppLogger.logError(
          'Failed to load the control schematic from $sidecar', e);
    }
    notifyListeners();
  }

  /// Reads one control-schematic document into the live state.
  ///
  /// Split out of the file load so a RECOVERED document can be applied through
  /// exactly the same parser — see [applyRecoveredRoom]. The caller has already
  /// emptied the state, the same bargain [_readAvFlowJson] makes.
  void _readSchematicJson(Map<String, dynamic> doc) {
      final positions = doc['positions'];
      if (positions is Map) {
        positions.forEach((id, xy) {
          if (xy is List && xy.length == 2) {
            schematicPositions[id.toString()] = Offset(
                (xy[0] as num).toDouble(), (xy[1] as num).toDouble());
          }
        });
      }
      final links = doc['links'];
      if (links is List) {
        for (final l in links) {
          if (l is Map && l['from'] != null && l['to'] != null) {
            schematicLinks.add({
              'from': l['from'].toString(),
              'to': l['to'].toString(),
              'color': (l['color'] ?? '2196F3').toString(),
              'label': (l['label'] ?? '').toString(),
            });
          }
        }
      }
      final hidden = doc['hiddenEdges'];
      if (hidden is List) {
        schematicHiddenEdges.addAll(hidden.map((e) => e.toString()));
      }
      final extras = doc['extraNodes'];
      if (extras is List) {
        for (final n in extras) {
          // An entry with no id or no name could not be drawn or linked to,
          // so it is dropped rather than becoming an unnameable empty box.
          if (n is! Map) continue;
          final id = n['id']?.toString() ?? '';
          final title = n['title']?.toString() ?? '';
          if (id.isEmpty || title.isEmpty) continue;
          schematicExtraNodes.add({
            'id': id,
            'title': title,
            'subtitle': (n['subtitle'] ?? '').toString(),
            'icon': (n['icon'] ?? '').toString(),
          });
        }
      }
      final avLan = doc['avLanTarget']?.toString().trim() ?? '';
      if (avLan.isNotEmpty) schematicAvLanTarget = avLan;
      final panel = doc['panelTarget']?.toString().trim() ?? '';
      if (panel.isNotEmpty) schematicPanelTarget = panel;
      final lineColors = doc['connColors'];
      if (lineColors is Map) {
        lineColors.forEach((index, hex) {
          final i = int.tryParse(index.toString());
          final value = int.tryParse(hex.toString(), radix: 16);
          if (i != null && value != null) {
            schematicConnColors[i] = Color(0xFF000000 | value);
          }
        });
      }
  }

  /// The control schematic as it goes to disk. Its own getter so the autosave
  /// can write the same document to a recovery folder without a second,
  /// drifting copy of the field list — see [writeAutosaveSnapshot].
  Map<String, dynamic> schematicLayoutAsJson() => {
        '__readme': 'Control Schematic tab layout for the Room Config '
            'Builder: dragged node positions, user-drawn connection lines, '
            'and boxes added by hand for equipment the control system does '
            'not talk to. (Before the tab was renamed this file was called '
            '<config>_schematic.json.)',
        'positions':
            schematicPositions.map((id, p) => MapEntry(id, [p.dx, p.dy])),
        'links': schematicLinks,
        'hiddenEdges': schematicHiddenEdges.toList(),
        'extraNodes': schematicExtraNodes,
        'avLanTarget': schematicAvLanTarget,
        'panelTarget': schematicPanelTarget,
        'connColors': {
          for (final e in schematicConnColors.entries)
            e.key.toString(): (e.value.toARGB32() & 0xFFFFFF)
                .toRadixString(16)
                .padLeft(6, '0'),
        },
      };

  /// Writes the layout sidecar. Returns the saved path, or '' when there is
  /// no working config file to sit next to (or the write failed).
  Future<String> saveSchematicLayout() async {
    final sidecar = schematicSidecarPath;
    if (sidecar.isEmpty) return '';
    try {
      const encoder = JsonEncoder.withIndent('  ');
      await File(sidecar).writeAsString(
        encoder.convert(schematicLayoutAsJson()),
      );

      // The write succeeded, so the pre-rename file is now a stale duplicate
      // that would quietly diverge from this one. Retire it — but only ever
      // AFTER the new file is safely on disk, and never if the two paths are
      // somehow the same.
      final legacy = legacySchematicSidecarPath;
      if (legacy.isNotEmpty && legacy != sidecar) {
        final old = File(legacy);
        if (old.existsSync()) {
          try {
            await old.delete();
            AppLogger.logInfo(
                'Control schematic moved to ${path.basename(sidecar)}; '
                'removed the old ${path.basename(legacy)}.');
          } catch (e) {
            // Not fatal: the layout is saved either way, and the loader
            // prefers the new name from here on.
            AppLogger.logError(
                'Saved the control schematic, but could not remove the old '
                '$legacy', e);
          }
        }
      }
      return sidecar;
    } catch (e, stack) {
      AppLogger.logError(
          'Failed to save the control schematic to $sidecar', e, stack);
      return '';
    }
  }

  // ---------------------------------------------------------------------
  //  AV FLOW TAB STATE
  //  The video/audio signal path, which the room config knows nothing about.
  //  Unlike the Schematic tab — where the diagram is DERIVED from the config
  //  and the state here is only the user's overrides — the AV diagram IS the
  //  document: nodes, their ports, the cables between them and the rack
  //  elevations all live here and nowhere else. Seeding from the config's
  //  device list is a convenience on first visit, not a source of truth.
  //
  //  Persists to "<config>_av_flow.json" beside the working config, on the
  //  same terms as the schematic sidecar: written on demand by Save, read
  //  back whenever that config is opened, and the user is asked first when
  //  both a session diagram and a saved file exist (avFlowNeedsChoice).
  // ---------------------------------------------------------------------

  // --- undo, one history per tab -------------------------------------------
  //  The AV sidecar is ONE document — devices, cables, racks, plans, the
  //  cabling drawing, the estimate — but it is edited on four separate pages,
  //  and a single shared history made those pages interfere: press Undo on the
  //  Cabling tab and you could roll back a device you had just moved on the
  //  AV Flow tab. So the history is split by SCOPE, one per tab.
  //
  //  What makes that safe is that the document already partitions cleanly.
  //  [kRoomSidecarKeys] divides every top-level key between the files the room
  //  is written to, exactly once each, and a test enforces it. Reusing that
  //  partition means a scope's keys are disjoint from every other scope's, so
  //  restoring one scope can never disturb another — and the split does not
  //  become a second, drifting opinion about what belongs with what.
  //
  //  Snapshots rather than inverse operations, still: an inverse for every
  //  mutator is a second implementation of the model that only gets exercised
  //  when something has already gone wrong. What changed is that a snapshot is
  //  now a SLICE — only the keys the edit's scopes own — so restoring it
  //  leaves the rest of the document exactly as it is.
  //
  //  A few edits genuinely span scopes: removing a location clears it off the
  //  devices that named it and off the control runs, and removing a device
  //  vacates its rack rail. Those are recorded as ONE entry covering every
  //  scope they touched, so undoing puts all of it back together. The price is
  //  [avUndoBlockedBy]: such an entry can only be undone while it is still the
  //  newest in each of its scopes, because rolling one of them back over a
  //  later edit would destroy work the user never asked to lose.

  /// One recorded edit: what it was called, and the state of each scope it
  /// touched BEFORE it happened.
  ///
  /// A key the document did not carry then is simply absent from the slice,
  /// which is how "there was no background image" survives the round trip —
  /// see [_restoreAvFlowSlices], which clears a scope's keys before laying its
  /// slice back down.
  final List<({String label, Map<AvUndoScope, Map<String, dynamic>> slices})>
  _avUndoStack = [];

  /// Edits undone but not yet superseded, so Redo can put them back.
  ///
  /// Cleared PER SCOPE by the next real edit rather than wholesale: once a
  /// scope has moved a different way its stored forward state is a branch
  /// nobody asked for, but a forward state for the Racks tab is still perfectly
  /// good after somebody retypes a cable count.
  final List<({String label, Map<AvUndoScope, Map<String, dynamic>> slices})>
  _avRedoStack = [];

  /// Deep enough to cover a run of edits across four tabs at once. Higher than
  /// it was because an entry is now a slice of the document rather than all of
  /// it, and because one list feeds four histories.
  static const int _kMaxUndoDepth = 60;

  /// Shorthands for the common case, which is an edit inside one tab.
  static const Set<AvUndoScope> _flowScope = {AvUndoScope.flow};
  static const Set<AvUndoScope> _racksScope = {AvUndoScope.racks};
  static const Set<AvUndoScope> _plansScope = {AvUndoScope.floorPlans};
  static const Set<AvUndoScope> _cablingScope = {AvUndoScope.cabling};

  /// The current value of every key [scopes] own.
  Map<AvUndoScope, Map<String, dynamic>> _sliceAvFlow(
    Iterable<AvUndoScope> scopes,
  ) {
    final doc = avFlowAsJson();
    return {
      for (final scope in scopes)
        scope: {
          for (final key in avUndoScopeKeys(scope))
            if (doc.containsKey(key)) key: doc[key],
        },
    };
  }

  /// Lays [slices] back over the live document, leaving every scope they do
  /// not cover exactly as it is.
  void _restoreAvFlowSlices(
    Map<AvUndoScope, Map<String, dynamic>> slices,
  ) {
    final doc = avFlowAsJson();
    for (final entry in slices.entries) {
      // Cleared first, so a key the slice does not carry goes back to being
      // absent instead of keeping whatever the current document has.
      for (final key in avUndoScopeKeys(entry.key)) {
        doc.remove(key);
      }
      doc.addAll(entry.value);
    }
    _clearAvFlowState();
    _readAvFlowJson(doc);
  }

  /// The entry [scope]'s Undo (or Redo) would act on, and — when there is one
  /// it cannot act on — the tab standing in the way.
  ///
  /// An entry covering several scopes is only actionable while it is the
  /// newest in ALL of them. Otherwise restoring it would roll one of those
  /// scopes back over an edit made since, which is work nobody asked to lose;
  /// undoing the later edit on its own tab clears the block.
  ({
    ({String label, Map<AvUndoScope, Map<String, dynamic>> slices})? edit,
    int at,
    String blockedBy,
  })
  _topAvEdit(
    List<({String label, Map<AvUndoScope, Map<String, dynamic>> slices})> stack,
    AvUndoScope scope,
  ) {
    final at = stack.lastIndexWhere((e) => e.slices.containsKey(scope));
    if (at < 0) return (edit: null, at: -1, blockedBy: '');
    final edit = stack[at];
    for (final other in edit.slices.keys) {
      if (other == scope) continue;
      if (stack.lastIndexWhere((e) => e.slices.containsKey(other)) != at) {
        return (
          edit: null,
          at: -1,
          blockedBy: kAvUndoScopeLabels[other] ?? other.name,
        );
      }
    }
    return (edit: edit, at: at, blockedBy: '');
  }

  bool canUndoAvFlow(AvUndoScope scope) =>
      _topAvEdit(_avUndoStack, scope).edit != null;

  bool canRedoAvFlow(AvUndoScope scope) =>
      _topAvEdit(_avRedoStack, scope).edit != null;

  /// What pressing Undo on [scope]'s tab would put back — shown on the button
  /// so it is never a guess ("Undo: Rack DMP 64").
  String avUndoLabel(AvUndoScope scope) =>
      _topAvEdit(_avUndoStack, scope).edit?.label ?? '';

  /// What pressing Redo would put back, named the same way.
  String avRedoLabel(AvUndoScope scope) =>
      _topAvEdit(_avRedoStack, scope).edit?.label ?? '';

  /// The tab whose later edit is holding [scope]'s Undo, or '' when nothing
  /// is. For the tooltip on a disabled button — see [_topAvEdit].
  String avUndoBlockedBy(AvUndoScope scope) =>
      _topAvEdit(_avUndoStack, scope).blockedBy;

  String avRedoBlockedBy(AvUndoScope scope) =>
      _topAvEdit(_avRedoStack, scope).blockedBy;

  /// Records the state BEFORE [label] happens, filed under the [scopes] it is
  /// about to change. Called at the top of every AV mutator; cheap enough to
  /// do unconditionally because a slice is small next to the widget tree that
  /// is about to rebuild anyway.
  // -------------------------------------------------------------------------
  //  WHO CHANGED WHAT IN THIS ROOM
  // -------------------------------------------------------------------------
  //  The job has kept a log of its own decisions for a while — lead times,
  //  orders, vendor pins. The ROOM kept none, so "who moved this device onto
  //  the other switcher" and "when did this field stop saying 9600" had no
  //  answer at all, and the only record of a room's working life was whatever
  //  somebody remembered.
  //
  //  Two hooks cover it, because the room already has exactly two places every
  //  edit passes through:
  //
  //    * [updateDeviceValue] — every field on the Wizard, Devices and System
  //      tabs. They are all schema-driven and they all write here.
  //    * [_pushAvUndo] — every edit to the drawing, the racks, the cabling and
  //      the plans. Anything undoable already carries a human label naming
  //      what it did, which is exactly what a log line wants to say.
  //
  //  Hooking those two rather than the two hundred mutation sites is the whole
  //  reason this is affordable, and it is not a compromise: an edit that
  //  reaches neither is an edit with no undo entry and no config change, which
  //  is not an edit.

  /// The value a field held when the CURRENT run of typing started, and when.
  ///
  /// Coalescing turns forty keystrokes into one log line — see [appendEdit] —
  /// but the line has to read 'was 9600, now 115200' rather than 'was 11520,
  /// now 115200'. That means the entry keeps the value from before the FIRST
  /// keystroke, and the only thing that knows what that was is whatever
  /// watched the first one go past.
  ({String key, Object? before, DateTime at})? _fieldEditRun;

  /// What to call the value a field is changing FROM: the one it held before
  /// this run of typing began, or the one it holds now when this is the first
  /// keystroke of a new run.
  Object? _beforeForRun(String key, Object? current) {
    final run = _fieldEditRun;
    final now = DateTime.now();
    if (run != null &&
        run.key == key &&
        now.difference(run.at).abs() < kEditCoalesceWindow) {
      _fieldEditRun = (key: key, before: run.before, at: now);
      return run.before;
    }
    _fieldEditRun = (key: key, before: current, at: now);
    return current;
  }

  /// 'was 9600, now 115200' — one field change, in words.
  ///
  /// Long values are cut: a log is a column on a screen, and a module path or a
  /// pasted block of text would push everything else off the row. Blank on
  /// either side reads as 'set'/'cleared' rather than as a pair of empty
  /// quotes.
  static String _fieldChangeSummary(Object? before, Object? after) {
    String show(Object? v) {
      final text = v?.toString().trim() ?? '';
      if (text.isEmpty) return '';
      return text.length <= 40 ? text : '${text.substring(0, 39)}…';
    }

    final was = show(before);
    final now = show(after);
    if (now.isEmpty) return was.isEmpty ? 'cleared' : 'cleared (was $was)';
    if (was.isEmpty) return 'set to $now';
    return 'was $was, now $now';
  }

  /// This room's log, oldest first. Written to `<config>_history.json`.
  final List<ProjectEdit> roomHistory = [];

  /// The whole room log, newest first — the order it is read in.
  List<ProjectEdit> get recentRoomHistory => roomHistory.reversed.toList();

  /// Records one change to the open room.
  ///
  /// Silently does nothing with no room open: the project's own tabs run with
  /// no config loaded, and a log entry filed against a room that is not there
  /// would attach itself to whichever room is opened next.
  void logRoomEdit({
    required String itemKey,
    required String field,
    required String summary,
    String itemName = '',
    bool coalesce = false,
    DateTime? at,
    String? user,
  }) {
    if (roomConfig.isEmpty) return;
    appendEdit(
      roomHistory,
      itemKey: itemKey,
      itemName: itemName,
      field: field,
      summary: summary,
      coalesce: coalesce,
      at: at,
      user: user,
    );
  }

  void _pushAvUndo(String label, Set<AvUndoScope> scopes) {
    // The room's log rides on the undo stack: anything undoable is an edit,
    // and it already carries a sentence saying what it did. See the note above
    // [logRoomEdit] on why these two hooks are the whole story.
    //
    // Coalesced, because a drag writes one entry per release and a rename
    // writes one per keystroke — filed under the tab it happened on, so a log
    // read months later says WHERE somebody was working as well as what they
    // touched.
    logRoomEdit(
      itemKey: 'drawing:${scopes.map((s) => s.name).join(',')}',
      itemName: scopes
          .map((s) => kAvUndoScopeLabels[s] ?? s.name)
          .join(', '),
      field: 'Drawing',
      summary: label,
      coalesce: true,
    );
    _avUndoStack.add((label: label, slices: _sliceAvFlow(scopes)));
    if (_avUndoStack.length > _kMaxUndoDepth) _avUndoStack.removeAt(0);
    // Only the branches this edit actually invalidates.
    _avRedoStack.removeWhere((e) => e.slices.keys.any(scopes.contains));
  }

  /// Puts [scope]'s tab back the way it was before its last edit. Returns what
  /// was undone, or '' when there was nothing it could act on.
  String undoAvFlow(AvUndoScope scope) {
    final found = _topAvEdit(_avUndoStack, scope);
    final edit = found.edit;
    if (edit == null) return '';
    _avUndoStack.removeAt(found.at);
    // The state being left, filed under the same name and the same scopes:
    // "Undo: Move box" and "Redo: Move box" have to describe the same edit
    // from the two sides, or the pair of buttons reads as two histories.
    _avRedoStack.add((
      label: edit.label,
      slices: _sliceAvFlow(edit.slices.keys),
    ));
    if (_avRedoStack.length > _kMaxUndoDepth) _avRedoStack.removeAt(0);
    _restoreAvFlowSlices(edit.slices);
    AppLogger.logInfo('Undid: ${edit.label}');
    notifyListeners();
    return edit.label;
  }

  /// Puts back what the last Undo on [scope]'s tab took away.
  ///
  /// The undo stack is pushed DIRECTLY rather than through [_pushAvUndo],
  /// which would drop this scope's forward history and make the second press
  /// of Redo impossible.
  String redoAvFlow(AvUndoScope scope) {
    final found = _topAvEdit(_avRedoStack, scope);
    final edit = found.edit;
    if (edit == null) return '';
    _avRedoStack.removeAt(found.at);
    _avUndoStack.add((
      label: edit.label,
      slices: _sliceAvFlow(edit.slices.keys),
    ));
    if (_avUndoStack.length > _kMaxUndoDepth) _avUndoStack.removeAt(0);
    _restoreAvFlowSlices(edit.slices);
    AppLogger.logInfo('Redid: ${edit.label}');
    notifyListeners();
    return edit.label;
  }

  /// Every box on the AV canvas, in creation order.
  final List<AvNode> avNodes = [];

  /// Every cable, in creation order (which is also their lane order).
  final List<AvCable> avCables = [];

  /// Rack frames on the elevation page.
  final List<RackFrame> avRacks = [];

  /// Node id -> where it sits in a rack. A device can only be in one place.
  ///
  /// Rack HARDWARE is keyed into this same map by its own id, because a vent
  /// plate occupies a rail on exactly the same terms a switcher does. Anything
  /// that reads a height out of here must go through [rackOccupantHeight].
  final Map<String, RackSlot> avRackSlots = {};

  /// Vent plates, blanks, shelves and drawers placed in the racks. Not nodes:
  /// none of them carry signal, so putting them on the flow canvas would fill
  /// it with boxes nothing is ever cabled to.
  final List<RackItem> avRackItems = [];

  /// Counter behind rack item ids ('RACKITEM_7').
  int _avRackItemCounter = 0;

  RackItem? avRackItemById(String id) {
    for (final i in avRackItems) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// How many rails whatever is stored under [id] takes up — a device, or a
  /// piece of rack hardware. Never 0: something you are trying to rack occupies
  /// at least one rail even when nobody filled its height in.
  int rackOccupantHeight(String id) {
    final node = avNodeById(id);
    if (node != null) return math.max(1, node.rackUnits);
    final item = avRackItemById(id);
    if (item != null) return math.max(1, item.rackUnits);
    return 1;
  }

  /// What to call whatever is racked at [id], for a tooltip or a message.
  String rackOccupantLabel(String id) =>
      avNodeById(id)?.label ?? avRackItemById(id)?.label ?? id;

  /// The rails whatever is stored under [id] wants left EMPTY, off its catalog
  /// entry. (0, 0) for anything the catalog says nothing about.
  ///
  /// Read from the catalog at draw time rather than copied onto the placement:
  /// clearance is a fact about the MODEL, and a room drawn last year should
  /// start warning the moment somebody records that the amplifier in it needs
  /// a rail above.
  ({int above, int below}) rackClearanceFor(String id) {
    final model = avNodeById(id)?.model ?? avRackItemById(id)?.catalogModel;
    if (model == null || model.trim().isEmpty) return (above: 0, below: 0);
    final template = avDeviceLibrary.templateForModel(model);
    if (template == null) return (above: 0, below: 0);
    return (
      above: math.max(0, template.clearanceAboveU),
      below: math.max(0, template.clearanceBelowU),
    );
  }

  /// Which rails of one rack face something wants kept clear, and why.
  ///
  /// U number -> the sentence the elevation shows on that rail. A WARNING and
  /// nothing more: the rack still accepts every drop, because the person in
  /// front of the frame knows things the catalog does not, and a tool that
  /// refuses a placement somebody has decided on is a tool they stop recording
  /// placements in.
  Map<int, String> rackClearanceWarnings({
    required String rackId,
    required RackFace face,
    required int heightU,
  }) {
    final out = <int, String>{};
    void mark(int u, String why) {
      if (u < 1 || u > heightU) return;
      final existing = out[u];
      // Two boxes can want the same rail; both reasons are worth reading.
      out[u] = existing == null || existing.contains(why)
          ? why
          : '$existing\n$why';
    }

    for (final entry in avRackSlots.entries) {
      final slot = entry.value;
      if (slot.rackId != rackId || slot.face != face) continue;
      final clearance = rackClearanceFor(entry.key);
      if (clearance.above == 0 && clearance.below == 0) continue;
      final label = rackOccupantLabel(entry.key);
      final top = slot.startU + rackOccupantHeight(entry.key) - 1;
      for (int i = 1; i <= clearance.above; i++) {
        mark(top + i, '$label wants ${clearance.above}U clear above it');
      }
      for (int i = 1; i <= clearance.below; i++) {
        mark(slot.startU - i, '$label wants ${clearance.below}U clear below it');
      }
    }
    return out;
  }

  /// Adds a piece of rack hardware and — when [rackId] and [startU] are given
  /// — drops it straight into a frame. Returns the stored item, whose id the
  /// rack slot map keys on, or null when a requested placement would not fit.
  ///
  /// Adding with no placement is deliberate and normal: parts are ordered
  /// before anybody decides which rail they land on, so an item can wait in
  /// the Racks page's waiting area, on the estimate and off the elevation,
  /// until it is dragged in.
  ///
  /// A REQUESTED placement that is refused is different — it takes the item
  /// back out again rather than leaving it floating, because the caller asked
  /// for a rail and silently landing somewhere else (or nowhere) is not what
  /// it asked for.
  RackItem? addAvRackItem(
    RackItem item, {
    String? rackId,
    RackFace face = RackFace.front,
    int? startU,
  }) {
    _pushAvUndo('Add ${item.label}', _racksScope);
    String id = item.id;
    if (id.isEmpty || avRackItemById(id) != null) {
      do {
        _avRackItemCounter++;
        id = 'RACKITEM_$_avRackItemCounter';
      } while (avRackItemById(id) != null);
    }
    final stored = item.withId(id);
    avRackItems.add(stored);
    if (rackId != null && startU != null) {
      // Placed through the sharing placer so a 1U blank can sit beside a
      // half-rack box on the same rail, exactly as a device would.
      final placed = avRackPlaceSharing(
        nodeId: id,
        rackId: rackId,
        face: face,
        startU: startU,
        recordUndo: false,
      );
      if (!placed) {
        avRackItems.removeWhere((i) => i.id == id);
        // The snapshot pushed above is now the state we are already in, so it
        // would make Undo a no-op the user has to press twice.
        if (_avUndoStack.isNotEmpty) _avUndoStack.removeLast();
        notifyListeners();
        return null;
      }
    }
    notifyListeners();
    return stored;
  }

  void updateAvRackItem(RackItem item) {
    final index = avRackItems.indexWhere((i) => i.id == item.id);
    if (index < 0) return;
    _pushAvUndo('Edit ${item.label}', _racksScope);
    avRackItems[index] = item;
    notifyListeners();
  }

  /// Points every placed piece of hardware called [label] that has no catalog
  /// entry yet at [catalogModel]. Returns how many were stamped.
  ///
  /// The other half of "add this line to the catalog" for rack hardware: the
  /// quote line is a GROUP of identical items in the frames, so promoting it
  /// has to reach all of them or the elevation and the estimate disagree about
  /// what the same plate is. Items that already name a catalog entry are left
  /// alone — they are a different part that happens to share a label.
  int linkAvRackItemsToCatalog({
    required String label,
    required String catalogModel,
  }) {
    final wanted = label.trim().toLowerCase();
    if (wanted.isEmpty || catalogModel.trim().isEmpty) return 0;
    final matched = [
      for (int i = 0; i < avRackItems.length; i++)
        if (avRackItems[i].catalogModel.trim().isEmpty &&
            avRackItems[i].label.trim().toLowerCase() == wanted)
          i,
    ];
    if (matched.isEmpty) return 0;
    _pushAvUndo('Catalog $label', _racksScope);
    for (final i in matched) {
      avRackItems[i] = avRackItems[i].copyWith(catalogModel: catalogModel);
    }
    AppLogger.logInfo(
        'Linked ${matched.length} rack item(s) named "$label" to catalog '
        'entry "$catalogModel".');
    notifyListeners();
    return matched.length;
  }

  /// Puts a different product under one placed piece of rack hardware.
  ///
  /// The frame keeps the item — its id, its rail and its notes are facts about
  /// this room — and what the CATALOG says it is comes off [template]: the
  /// name, the category, the part number, how many rails it takes and what it
  /// costs. The same trade the device swap makes on the diagram.
  ///
  /// Returns false when it had to come off its rail: a 1U blank replaced by a
  /// 3U shelf may not fit where the blank was, and a taller box silently
  /// overlapping its neighbour is a rack elevation that lies. It stays in the
  /// room, un-racked, for somebody to place.
  bool swapAvRackItem(RackItem item, AvDeviceTemplate template) {
    final was = item.catalogModel.trim().isNotEmpty
        ? item.catalogModel
        : item.label;
    final heightU = math.max(1, template.rackUnits);
    updateAvRackItem(
      item.copyWith(
        catalogModel: template.model,
        // Only the part of the name that WAS the old product — "Vent plate,
        // above the amp" keeps where it is while what it is changes.
        label: renamedForModel(item.label, was, template.model),
        category: template.category.trim().isEmpty
            ? item.category
            : template.category,
        partNumber: template.partNumber,
        rackUnits: heightU,
        // The copy on the placed item is only the fallback for when the entry
        // is gone, but it has to be the NEW part's fallback.
        price: template.price,
      ),
    );
    final slot = avRackSlots[item.id];
    if (slot == null) return true;
    if (avRackSpanIsFree(
      rackId: slot.rackId,
      face: slot.face,
      startU: slot.startU,
      heightU: heightU,
      slice: slot.slice,
      ignoreNodeId: item.id,
    )) {
      return true;
    }
    setAvRackSlot(item.id, null);
    return false;
  }

  /// Points everything in THIS ROOM that names [oldModel] at [newModel], and
  /// says how much it reached.
  ///
  /// THE HALF A CATALOG RENAME ALWAYS MISSED. Renaming an entry moves the
  /// entry; it does not move the vent plate in rack 2, the box on the diagram,
  /// the line on the quote or the block in the config, all of which record the
  /// model by NAME. Before this, editing "Vent plate" into "1RU fan panel"
  /// left every one of them still saying "Vent plate" and quietly unpriced,
  /// because the entry they named was gone.
  ///
  /// Names as well as models: a rack item IS its label, and a device called
  /// "Rack DSP — DMP 128" is named after the product — see [renamedForModel]
  /// for why only the model part of a name moves.
  ///
  /// Room prices follow too. An override is filed under a line key built out
  /// of the model, so leaving it behind would drop the price somebody typed
  /// the moment the part was renamed.
  ({int nodes, int rackItems, int costLines, int blocks}) renameAvCatalogModel(
    String oldModel,
    String newModel,
  ) => _walkModelUses(oldModel, newModel);

  /// What a rename of [model] WOULD reach, without touching any of it.
  ///
  /// Asked before the question is put: a rename that moves nothing needs no
  /// dialog, and one that moves eleven things should say eleven.
  ///
  /// The same walk that does the work, so the count and the change cannot
  /// disagree — which is the whole reason this is not a second loop.
  ({int nodes, int rackItems, int costLines, int blocks}) avUsesOfModel(
    String model,
  ) => _walkModelUses(model, '');

  /// Counts everything in this room that names [oldModel], and — when
  /// [newModel] is given — points it at that instead. See
  /// [renameAvCatalogModel] for why any of this is necessary.
  ({int nodes, int rackItems, int costLines, int blocks}) _walkModelUses(
    String oldModel,
    String newModel,
  ) {
    final was = oldModel.trim();
    final now = newModel.trim();
    // Counting, not renaming: the walk is the same and nothing is written.
    final apply = now.isNotEmpty;
    if (was.isEmpty ||
        (apply &&
            AvDeviceLibrary.normalizeModel(was) ==
                AvDeviceLibrary.normalizeModel(now))) {
      return (nodes: 0, rackItems: 0, costLines: 0, blocks: 0);
    }
    bool isOld(String model) =>
        model.trim().isNotEmpty &&
        AvDeviceLibrary.normalizeModel(model) ==
            AvDeviceLibrary.normalizeModel(was);
    String renamed(String name) => renamedForModel(name, was, now);

    if (apply) {
      _pushAvUndo('Rename $was', {AvUndoScope.flow, AvUndoScope.racks});
    }

    var nodes = 0;
    for (var i = 0; i < avNodes.length; i++) {
      if (!isOld(avNodes[i].model)) continue;
      if (apply) {
        avNodes[i] = avNodes[i].copyWith(
          model: now,
          label: renamed(avNodes[i].label),
        );
      }
      nodes++;
    }

    var rackItems = 0;
    for (var i = 0; i < avRackItems.length; i++) {
      final item = avRackItems[i];
      // Either it names the entry, or it is a one-off that was typed in under
      // the entry's own name — the vent plate somebody placed before anybody
      // catalogued it. Both are the same part to everyone who reads the rack.
      if (!isOld(item.catalogModel) &&
          !(item.catalogModel.trim().isEmpty && isOld(item.label))) {
        continue;
      }
      if (apply) {
        avRackItems[i] = item.copyWith(
          catalogModel: now,
          label: renamed(item.label),
        );
      }
      rackItems++;
    }

    var costLines = 0;
    for (final list in [
      avCost.extraEquipment,
      avCost.extraHardware,
      avCost.extraCables,
      avCost.items,
    ]) {
      for (var i = 0; i < list.length; i++) {
        if (!isOld(list[i].catalogModel)) continue;
        if (apply) {
          list[i] = list[i].copyWith(
            catalogModel: now,
            description: renamed(list[i].description),
          );
        }
        costLines++;
      }
    }

    // The price keys the estimate builds out of a model — the device group's
    // and the rack group's. Moved rather than dropped: the figure was typed
    // against this part, and the part is the one that has been renamed.
    if (apply) {
      for (final entry in {
        'model:${was.toLowerCase()}': 'model:${now.toLowerCase()}',
        'rackitem:model:${was.toLowerCase()}': 'rackitem:model:'
            '${now.toLowerCase()}',
      }.entries) {
        final price = avCost.priceOverrides.remove(entry.key);
        if (price != null) avCost.priceOverrides[entry.value] = price;
      }
    }

    // The control side. A block records the model it was specified as, and
    // the name people read is usually built out of it.
    var blocks = 0;
    for (final key in roomConfig.keys.toList()) {
      final dev = roomConfig[key];
      if (dev is! Map || !isOld(dev['model']?.toString() ?? '')) continue;
      if (apply) {
        dev['model'] = now;
        _forgetConversionOrigin(key, 'model');
        final name = dev['name']?.toString() ?? '';
        final after = renamed(name);
        if (after != name) {
          dev['name'] = after;
          _forgetConversionOrigin(key, 'name');
        }
      }
      blocks++;
    }

    if (!apply) {
      return (
        nodes: nodes,
        rackItems: rackItems,
        costLines: costLines,
        blocks: blocks,
      );
    }
    AppLogger.logInfo(
      'Renamed "$was" to "$now": $nodes box(es), $rackItems rack item(s), '
      '$costLines quote line(s), $blocks config block(s).',
    );
    notifyListeners();
    return (
      nodes: nodes,
      rackItems: rackItems,
      costLines: costLines,
      blocks: blocks,
    );
  }

  void removeAvRackItem(String itemId) {
    final item = avRackItemById(itemId);
    if (item == null) return;
    _pushAvUndo('Remove ${item.label}', _racksScope);
    avRackItems.removeWhere((i) => i.id == itemId);
    final vacated = avRackSlots.remove(itemId);
    if (vacated != null) {
      avRepackRow(vacated.rackId, vacated.face, vacated.startU);
    }
    notifyListeners();
  }

  // --- where things are in the room ----------------------------------------
  //  Locations, the screen/shade control runs between them, and the floor
  //  plans they are drawn on. All three live in the AV sidecar with the
  //  diagram, because they describe the same room and are useless apart from
  //  it: a location list with no devices naming it counts nothing.

  /// Named places in the room, in the order the user arranged them.
  final List<RoomLocation> avLocations = [];

  /// Screen and shade control runs — two ends and no signal.
  final List<ScreenSwitch> avScreenSwitches = [];

  /// Floor plans, with their callouts.
  final List<FloorPlan> avFloorPlans = [];

  int _avLocationCounter = 0;
  int _avScreenSwitchCounter = 0;
  int _avFloorPlanCounter = 0;
  int _avCalloutCounter = 0;

  RoomLocation? avLocationById(String id) {
    for (final l in avLocations) {
      if (l.id == id) return l;
    }
    return null;
  }

  /// What to print for a location id: its display name, or '' when the id is
  /// blank or names a location that has since been deleted.
  String avLocationName(String id) =>
      id.isEmpty ? '' : (avLocationById(id)?.displayName ?? '');

  RoomLocation addAvLocation(RoomLocation location) {
    _pushAvUndo('Add ${location.name}', _plansScope);
    String id = location.id;
    if (id.isEmpty || avLocationById(id) != null) {
      do {
        _avLocationCounter++;
        id = 'LOC_$_avLocationCounter';
      } while (avLocationById(id) != null);
    }
    final stored = location.withId(id);
    avLocations.add(stored);
    notifyListeners();
    return stored;
  }

  void updateAvLocation(RoomLocation location) {
    final index = avLocations.indexWhere((l) => l.id == location.id);
    if (index < 0) return;
    _pushAvUndo('Edit ${location.name}', _plansScope);
    avLocations[index] = location;
    notifyListeners();
  }

  /// Moves a location's marker ON ONE SHEET, without an undo entry per pointer
  /// event — one drag should be one undo, the same bargain the cable waypoint
  /// handles make.
  ///
  /// [planId] blank means the sheet currently open, which is what every gesture
  /// on the Floor Plan tab wants.
  void moveAvLocationMarker(
    String planId,
    String id,
    Offset planPos, {
    bool recordUndo = true,
  }) {
    final sheet = planId.isEmpty ? activeFloorPlan : avFloorPlanById(planId);
    if (sheet == null) return;
    final index = avFloorPlans.indexWhere((p) => p.id == sheet.id);
    if (index < 0 || avLocationById(id) == null) return;
    if (recordUndo) _pushAvUndo('Move ${avLocationName(id)}', _plansScope);
    avFloorPlans[index] = sheet.withMarker(id, planPos);
    notifyListeners();
  }

  /// What one sheet's paper is painted. Null puts it back to the default
  /// black — see [FloorPlan.paper].
  void setAvPlanPaperColor(String planId, Color? color) {
    final sheet = planId.isEmpty ? activeFloorPlan : avFloorPlanById(planId);
    if (sheet == null) return;
    final index = avFloorPlans.indexWhere((p) => p.id == sheet.id);
    if (index < 0) return;
    _pushAvUndo('Sheet colour', _plansScope);
    avFloorPlans[index] = sheet.copyWith(
      paperColor: color,
      clearPaperColor: color == null,
    );
    notifyListeners();
  }

  /// Takes an undo snapshot of the floor plans before a gesture that will
  /// write through them over and over. Dragging a bend writes on every pointer
  /// event, and one drag has to be one undo.
  void pushFloorPlanUndo(String label) => _pushAvUndo(label, _plansScope);

  /// Steers a cable run on ONE sheet: the bends it passes through, in order,
  /// in that sheet's image coordinates. An empty list hands it back to the
  /// router.
  ///
  /// Per sheet, like the markers — see [FloorPlan.runWaypoints]. The pull is
  /// the room's; the shape of the line is this drawing's.
  ///
  /// [recordUndo] false is for the middle of a drag: one drag is one undo, not
  /// one per pointer event.
  void setAvRunWaypoints(
    String planId,
    String runId,
    List<Offset> points, {
    bool recordUndo = true,
  }) {
    final sheet = planId.isEmpty ? activeFloorPlan : avFloorPlanById(planId);
    if (sheet == null || runId.isEmpty) return;
    final index = avFloorPlans.indexWhere((p) => p.id == sheet.id);
    if (index < 0) return;
    if (recordUndo) _pushAvUndo('Route a run', _plansScope);
    avFloorPlans[index] = sheet.withRunWaypoints(runId, points);
    notifyListeners();
  }

  /// Moves a run's caption on ONE sheet, as a nudge from where the drawing
  /// put it — see [FloorPlan.runLabelOffsets]. [Offset.zero] hands it back to
  /// the automatic placement.
  ///
  /// [recordUndo] false is for the middle of a drag.
  void setAvRunLabelOffset(
    String planId,
    String edgeKey,
    Offset by, {
    bool recordUndo = true,
  }) {
    final sheet = planId.isEmpty ? activeFloorPlan : avFloorPlanById(planId);
    if (sheet == null || edgeKey.isEmpty) return;
    final index = avFloorPlans.indexWhere((p) => p.id == sheet.id);
    if (index < 0) return;
    if (recordUndo) {
      _pushAvUndo(
        by == Offset.zero ? 'Put a label back' : 'Move a label',
        _plansScope,
      );
    }
    avFloorPlans[index] = sheet.withRunLabelOffset(edgeKey, by);
    notifyListeners();
  }

  /// Sets the blank space around the plan image on [planId].
  ///
  /// Growing the LEFT or TOP margin moves the image away from the sheet's
  /// origin, so everything already drawn is shifted by the same amount: a
  /// marker placed on a wall stays on that wall, a run keeps its bends, and
  /// the key keeps its corner. Without that, adding a margin would quietly
  /// slide every mark on the drawing off the thing it was marking.
  void setAvPlanMargins(String planId, EdgeInsets margins) {
    final sheet = planId.isEmpty ? activeFloorPlan : avFloorPlanById(planId);
    if (sheet == null) return;
    final index = avFloorPlans.indexWhere((p) => p.id == sheet.id);
    if (index < 0) return;
    final clean = EdgeInsets.fromLTRB(
      math.max(0, margins.left),
      math.max(0, margins.top),
      math.max(0, margins.right),
      math.max(0, margins.bottom),
    );
    if (clean == sheet.margins) return;
    _pushAvUndo('Space around the plan', _plansScope);

    final shift = Offset(
      clean.left - sheet.margins.left,
      clean.top - sheet.margins.top,
    );
    var next = sheet.copyWith(margins: clean);
    if (shift != Offset.zero) {
      next = next.copyWith(
        markers: {
          for (final e in sheet.markers.entries) e.key: e.value + shift,
        },
        callouts: [
          for (final c in sheet.callouts) c.copyWith(pos: c.pos + shift),
        ],
        annotations: [
          for (final a in sheet.annotations) a.shifted(shift),
        ],
        runWaypoints: {
          for (final e in sheet.runWaypoints.entries)
            e.key: [for (final w in e.value) w + shift],
        },
        keyPos: sheet.keyPos + shift,
      );
    }
    avFloorPlans[index] = next;
    notifyListeners();
  }

  /// Sets the plate and ink one kind of text is printed in on [planId].
  ///
  /// A drawing decision like the key's position or a bend in a run, so it goes
  /// through the plans' undo scope with them: recolouring every label on a
  /// sheet and not being able to take it back is not a change anybody tries
  /// twice.
  void setAvPlanLabelStyle(
    String planId,
    PlanTextKind kind,
    PlanLabelStyle style,
  ) {
    final sheet = planId.isEmpty ? activeFloorPlan : avFloorPlanById(planId);
    if (sheet == null) return;
    final index = avFloorPlans.indexWhere((p) => p.id == sheet.id);
    if (index < 0) return;
    _pushAvUndo(
      style.isDefault
          ? '${kPlanTextKindLabels[kind]} back to standard'
          : 'Recolour ${kPlanTextKindLabels[kind]?.toLowerCase()}',
      _plansScope,
    );
    avFloorPlans[index] = sheet.withLabelStyle(kind, style);
    notifyListeners();
  }

  /// Takes a location off ONE sheet. The location itself stays in the room —
  /// it is still where the devices are, it is just not drawn on this drawing.
  void removeAvLocationMarker(String planId, String id) {
    final sheet = planId.isEmpty ? activeFloorPlan : avFloorPlanById(planId);
    if (sheet == null || !sheet.hasMarker(id)) return;
    final index = avFloorPlans.indexWhere((p) => p.id == sheet.id);
    if (index < 0) return;
    _pushAvUndo('Take ${avLocationName(id)} off ${sheet.name}', _plansScope);
    avFloorPlans[index] = sheet.withoutMarker(id);
    notifyListeners();
  }

  /// Where [locationId] sits on [planId] (or on the open sheet), or null when
  /// it is not on that sheet at all.
  Offset? avLocationMarker(String planId, String locationId) {
    final sheet = planId.isEmpty ? activeFloorPlan : avFloorPlanById(planId);
    return sheet?.markerFor(locationId);
  }

  /// True when [locationId] is drawn on ANY sheet. What the reports ask: "is
  /// this place on a drawing somewhere", not "is it on the one you have open".
  bool isLocationOnAnySheet(String locationId) =>
      avFloorPlans.any((p) => p.hasMarker(locationId));

  /// The sheets [locationId] appears on, in sheet order.
  List<FloorPlan> sheetsShowing(String locationId) =>
      avFloorPlans.where((p) => p.hasMarker(locationId)).toList();

  /// Moves markers written by a version that kept ONE set of coordinates per
  /// room onto the first sheet, which is the sheet they were drawn on.
  ///
  /// Only ever fires on a room whose sheets carry no markers of their own, so
  /// re-saving a migrated room and opening it again is a no-op rather than a
  /// second migration writing over what has since been moved.
  void _migrateLegacyPlanMarkers() {
    if (avFloorPlans.isEmpty) return;
    if (avFloorPlans.any((p) => p.markers.isNotEmpty)) return;
    final legacy = {
      for (final l in avLocations)
        if (l.isPlaced) l.id: l.planPos,
    };
    if (legacy.isEmpty) return;
    avFloorPlans[0] = avFloorPlans[0].copyWith(markers: legacy);
  }

  /// Removes a location and unsets it everywhere it was named.
  ///
  /// Leaving the id behind on the devices would give them a location that
  /// resolves to nothing — which reads in the report as a blank cell that
  /// cannot be filled in from the location list, because the entry it names
  /// is gone. Clearing them makes the devices honestly unassigned again.
  void removeAvLocation(String id) {
    final location = avLocationById(id);
    if (location == null) return;
    _pushAvUndo('Remove ${location.name}', const {AvUndoScope.floorPlans, AvUndoScope.flow, AvUndoScope.cabling});
    avLocations.removeWhere((l) => l.id == id);
    for (int i = 0; i < avNodes.length; i++) {
      if (avNodes[i].locationId == id) {
        avNodes[i] = avNodes[i].copyWith(locationId: kNoLocationId);
      }
    }
    for (int i = 0; i < avScreenSwitches.length; i++) {
      final s = avScreenSwitches[i];
      avScreenSwitches[i] = s.copyWith(
        startLocationId: s.startLocationId == id ? kNoLocationId : null,
        endLocationId: s.endLocationId == id ? kNoLocationId : null,
      );
    }
    // A callout pointing at a location that no longer exists becomes a plain
    // note rather than a dangling reference nobody can resolve on site, and
    // the marker comes off every sheet that was drawing it.
    for (int p = 0; p < avFloorPlans.length; p++) {
      final plan = avFloorPlans[p];
      avFloorPlans[p] = plan.copyWith(
        callouts: [
          for (final c in plan.callouts)
            if (c.target == CalloutTarget.location && c.targetId == id)
              c.copyWith(target: CalloutTarget.note, targetId: '')
            else
              c,
        ],
        markers: {...plan.markers}..remove(id),
      );
    }
    notifyListeners();
  }

  /// Puts a device in a location (or takes it out of one when [locationId]
  /// is blank).
  void setAvNodeLocation(String nodeId, String locationId) {
    final index = avNodes.indexWhere((n) => n.id == nodeId);
    if (index < 0) return;
    if (avNodes[index].locationId == locationId) return;
    _pushAvUndo('Locate ${avNodes[index].label}', _flowScope);
    avNodes[index] = avNodes[index].copyWith(locationId: locationId);
    notifyListeners();
  }

  /// Creates the starter location list for a room that has none. Returns how
  /// many were added, so the caller can say nothing happened.
  int seedDefaultAvLocations() {
    if (avLocations.isNotEmpty) return 0;
    for (final d in kDefaultRoomLocations) {
      addAvLocation(
        RoomLocation(
          id: '',
          name: d.name,
          zone: d.zone,
          callout: d.callout,
        ),
      );
    }
    return kDefaultRoomLocations.length;
  }

  // --- screen / shade control runs -----------------------------------------

  ScreenSwitch addAvScreenSwitch(ScreenSwitch item) {
    _pushAvUndo('Add ${item.label}', _cablingScope);
    String id = item.id;
    if (id.isEmpty || avScreenSwitches.any((s) => s.id == id)) {
      do {
        _avScreenSwitchCounter++;
        id = 'SCRSW_$_avScreenSwitchCounter';
      } while (avScreenSwitches.any((s) => s.id == id));
    }
    final stored = item.withId(id);
    avScreenSwitches.add(stored);
    notifyListeners();
    return stored;
  }

  void updateAvScreenSwitch(ScreenSwitch item) {
    final index = avScreenSwitches.indexWhere((s) => s.id == item.id);
    if (index < 0) return;
    _pushAvUndo('Edit ${item.label}', _cablingScope);
    avScreenSwitches[index] = item;
    notifyListeners();
  }

  void removeAvScreenSwitch(String id) {
    final index = avScreenSwitches.indexWhere((s) => s.id == id);
    if (index < 0) return;
    _pushAvUndo('Remove ${avScreenSwitches[index].label}', _cablingScope);
    avScreenSwitches.removeAt(index);
    notifyListeners();
  }

  // --- floor plans ---------------------------------------------------------

  FloorPlan? avFloorPlanById(String id) {
    for (final p in avFloorPlans) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// The sheet being worked on. Session state, not saved: which drawing you
  /// had open is not a fact about the room.
  String _activeFloorPlanId = '';

  /// The sheet the Floor Plan tab is showing and the AV canvas draws behind
  /// itself.
  ///
  /// A room has more than one sheet as soon as it has more than one storey, or
  /// a reflected ceiling plan next to the furniture plan, or a demolition
  /// sheet beside the new work. Falls back to the first, which is what a room
  /// with one sheet has always used.
  FloorPlan? get activeFloorPlan {
    if (avFloorPlans.isEmpty) return null;
    return avFloorPlanById(_activeFloorPlanId) ?? avFloorPlans.first;
  }

  /// Kept under its old name for the callers that want "the room's plan"
  /// without caring which sheet is open — the exports and the workbook.
  FloorPlan? get primaryFloorPlan => activeFloorPlan;

  /// Every sheet that has a drawing behind it, for the exports that produce
  /// one image per sheet.
  List<FloorPlan> get floorPlanSheetsWithImages =>
      avFloorPlans.where((p) => p.hasImage).toList();

  void selectFloorPlan(String id) {
    if (_activeFloorPlanId == id) return;
    _activeFloorPlanId = id;
    notifyListeners();
  }

  /// Adds an empty sheet and opens it. The drawing is imported afterwards, so
  /// a sheet can be named and ordered before anybody has the PDF for it.
  FloorPlan addFloorPlanSheet({String name = ''}) {
    final n = avFloorPlans.length + 1;
    final sheet = addAvFloorPlan(
      FloorPlan(id: '', name: name.trim().isEmpty ? 'Sheet $n' : name.trim()),
    );
    _activeFloorPlanId = sheet.id;
    notifyListeners();
    return sheet;
  }

  /// Copies a sheet with its callouts — the way a reflected ceiling plan gets
  /// started from the furniture plan that already has every location on it.
  FloorPlan? duplicateFloorPlanSheet(String id) {
    final source = avFloorPlanById(id);
    if (source == null) return null;
    final copy = addAvFloorPlan(
      source.copyWith(name: '${source.name} copy').withId(''),
    );
    _activeFloorPlanId = copy.id;
    notifyListeners();
    return copy;
  }

  /// Moves a sheet in the running order. Sheets are read in order — Level 1,
  /// Level 2, RCP — and a set that will not reorder is a set that gets
  /// rebuilt instead.
  void moveFloorPlanSheet(String id, int toIndex) {
    final from = avFloorPlans.indexWhere((p) => p.id == id);
    if (from < 0) return;
    final to = toIndex.clamp(0, avFloorPlans.length - 1);
    if (from == to) return;
    _pushAvUndo('Reorder floor plans', _plansScope);
    avFloorPlans.insert(to, avFloorPlans.removeAt(from));
    notifyListeners();
  }

  FloorPlan addAvFloorPlan(FloorPlan plan) {
    _pushAvUndo('Add ${plan.name}', _plansScope);
    String id = plan.id;
    if (id.isEmpty || avFloorPlanById(id) != null) {
      do {
        _avFloorPlanCounter++;
        id = 'PLAN_$_avFloorPlanCounter';
      } while (avFloorPlanById(id) != null);
    }
    final stored = plan.withId(id);
    avFloorPlans.add(stored);
    notifyListeners();
    return stored;
  }

  void updateAvFloorPlan(FloorPlan plan) {
    final index = avFloorPlans.indexWhere((p) => p.id == plan.id);
    if (index < 0) return;
    _pushAvUndo('Edit ${plan.name}', _plansScope);
    avFloorPlans[index] = plan;
    notifyListeners();
  }

  void removeAvFloorPlan(String id) {
    final plan = avFloorPlanById(id);
    if (plan == null) return;
    _pushAvUndo('Remove ${plan.name}', _plansScope);
    avFloorPlans.removeWhere((p) => p.id == id);
    // Land on a sheet that still exists rather than on nothing.
    if (_activeFloorPlanId == id) {
      _activeFloorPlanId = avFloorPlans.isEmpty ? '' : avFloorPlans.first.id;
    }
    // The locations keep their marker coordinates: they are meaningless
    // without a plan but harmless, and re-importing the same drawing puts
    // every marker straight back where it was.
    notifyListeners();
  }

  /// Adds a callout to [planId]. Returns it, or null when the plan is gone.
  FloorPlanCallout? addAvCallout(String planId, FloorPlanCallout callout) {
    final index = avFloorPlans.indexWhere((p) => p.id == planId);
    if (index < 0) return null;
    _pushAvUndo('Add callout', _plansScope);
    final plan = avFloorPlans[index];
    final taken = {for (final c in plan.callouts) c.id};
    String id = callout.id;
    if (id.isEmpty || taken.contains(id)) {
      do {
        _avCalloutCounter++;
        id = 'CALLOUT_$_avCalloutCounter';
      } while (taken.contains(id));
    }
    final stored = callout.withId(id);
    avFloorPlans[index] = plan.copyWith(
      callouts: [...plan.callouts, stored],
    );
    notifyListeners();
    return stored;
  }

  void updateAvCallout(String planId, FloorPlanCallout callout,
      {bool recordUndo = true}) {
    final index = avFloorPlans.indexWhere((p) => p.id == planId);
    if (index < 0) return;
    final plan = avFloorPlans[index];
    final at = plan.callouts.indexWhere((c) => c.id == callout.id);
    if (at < 0) return;
    if (recordUndo) _pushAvUndo('Edit callout ${callout.tag}', _plansScope);
    final next = List<FloorPlanCallout>.from(plan.callouts);
    next[at] = callout;
    avFloorPlans[index] = plan.copyWith(callouts: next);
    notifyListeners();
  }

  void removeAvCallout(String planId, String calloutId) {
    final index = avFloorPlans.indexWhere((p) => p.id == planId);
    if (index < 0) return;
    _pushAvUndo('Remove callout', _plansScope);
    final plan = avFloorPlans[index];
    avFloorPlans[index] = plan.copyWith(
      callouts: [
        for (final c in plan.callouts)
          if (c.id != calloutId) c,
      ],
    );
    notifyListeners();
  }

  // --- the signal flow's backdrop -------------------------------------------

  /// The picture behind the AV Flow canvas, if any. See [DiagramBackground].
  DiagramBackground avFlowBackground = const DiagramBackground();

  /// Puts [imageFile] (already copied in by [importRoomImage]) behind the
  /// canvas at its natural [size], keeping whatever opacity and scale were set.
  void setAvFlowBackgroundImage(String imageFile, Size size) {
    _pushAvUndo(imageFile.isEmpty ? 'Remove the background' : 'Set a background', _flowScope);
    avFlowBackground = avFlowBackground.copyWith(
      imageFile: imageFile,
      imageSize: size,
    );
    notifyListeners();
  }

  /// How strongly the backdrop shows, and how much of the canvas it covers.
  void setAvFlowBackgroundView({double? opacity, double? scale}) {
    _pushAvUndo('Adjust the background', _flowScope);
    avFlowBackground = avFlowBackground.copyWith(
      opacity: opacity,
      scale: scale,
    );
    notifyListeners();
  }

  void clearAvFlowBackground() {
    if (!avFlowBackground.hasImage) return;
    _pushAvUndo('Remove the background', _flowScope);
    avFlowBackground = const DiagramBackground();
    notifyListeners();
  }

  // --- the cabling schematic ------------------------------------------------
  //  Only what somebody typed or moved is kept; the drawing itself is derived
  //  from the room every time it is shown (see cabling_schematic.dart).

  final CablingOverrides avCabling = CablingOverrides();

  int _avCablingBoxCounter = 0;
  int _avCablingRunCounter = 0;

  /// The drawing as it should be shown: derived from the room, overrides on.
  CablingSchematic cablingSchematic(AvFlowModel model) => buildCablingSchematic(
    model: model,
    locations: avLocations,
    overrides: avCabling,
    // The room's palette, so recolouring HDBaseT on the signal flow moves the
    // AV runs on the cabling sheet with it.
    palette: avSignalColors,
  );

  /// [recordUndo] false while a drag is in flight — one entry for the move.
  void setCablingBoxPosition(String id, Offset pos, {bool recordUndo = true}) {
    if (recordUndo) _pushAvUndo('Move box', _cablingScope);
    avCabling.positions[id] = pos;
    notifyListeners();
  }

  void setCablingBoxLabel(String id, String label) {
    _pushAvUndo('Rename box', _cablingScope);
    avCabling.labels[id] = label;
    notifyListeners();
  }

  void setCablingBoxBody(String id, String body) {
    _pushAvUndo('Edit notes', _cablingScope);
    avCabling.bodies[id] = body;
    notifyListeners();
  }

  /// Types a count over the one the room worked out. Passing null puts the
  /// derived figure back, which is the only way out of an override.
  void setCablingBundleCount(String id, double? count) {
    _pushAvUndo('Set cable count', _cablingScope);
    if (count == null) {
      avCabling.counts.remove(id);
    } else {
      avCabling.counts[id] = count;
    }
    notifyListeners();
  }

  void setCablingBundleType(String id, String? type) {
    _pushAvUndo('Set cable type', _cablingScope);
    if (type == null || type.trim().isEmpty) {
      avCabling.cableTypes.remove(id);
    } else {
      avCabling.cableTypes[id] = type.trim();
    }
    notifyListeners();
  }

  /// Colours one run on the drawing. Null puts it back to the colour the room
  /// gives that signal, which is the only way out of a recolour.
  void setCablingBundleColor(String id, int? argb) {
    _pushAvUndo('Set cable colour', _cablingScope);
    if (argb == null) {
      avCabling.colors.remove(id);
    } else {
      avCabling.colors[id] = argb;
    }
    notifyListeners();
  }

  /// Colours every run of one CABLE, on the drawing and on the floor plan
  /// alike. Null puts the key's own colour back.
  ///
  /// [colorKeys] is what [cablingColorKey] returns for the runs concerned —
  /// plural because a cable type can be pulled under more than one category
  /// ("Cat 6a" as AV and as network), and somebody recolouring the Cat 6a layer
  /// means the layer they are looking at, not one half of it.
  void setCablingTypeColor(Iterable<String> colorKeys, int? argb) {
    final keys = colorKeys.where((k) => k.isNotEmpty).toSet();
    if (keys.isEmpty) return;
    _pushAvUndo('Set the colour for this cable', _cablingScope);
    for (final key in keys) {
      if (argb == null) {
        avCabling.typeColors.remove(key);
      } else {
        avCabling.typeColors[key] = argb;
      }
    }
    notifyListeners();
  }

  /// Hands every cable type back the colour the key gives it, in one go —
  /// the way the signal flow's palette dialog resets its own colours.
  void resetCablingTypeColors() {
    if (avCabling.typeColors.isEmpty) return;
    _pushAvUndo("Back to the key's colours", _cablingScope);
    avCabling.typeColors.clear();
    notifyListeners();
  }

  /// Moves a run's caption on the cabling drawing, as a nudge from where the
  /// sheet put it. [Offset.zero] hands it back to the automatic placement.
  ///
  /// A nudge rather than a position, for the reason the floor plan stores one:
  /// the automatic spot follows the line, so a label moved out of the way of a
  /// box stays out of the way of it when that box is dragged half a metre.
  void setCablingLabelOffset(String edgeKey, Offset by) {
    if (edgeKey.isEmpty) return;
    _pushAvUndo(
      by == Offset.zero ? 'Put a label back' : 'Move a label',
      _cablingScope,
    );
    if (by == Offset.zero) {
      avCabling.labelOffsets.remove(edgeKey);
    } else {
      avCabling.labelOffsets[edgeKey] = by;
    }
    notifyListeners();
  }

  /// Moves where one end of a run lands on its box, as a fraction of the box.
  /// Null puts it back in the middle.
  ///
  /// Cable comes into a floor box from one side, and four runs all pointing at
  /// the centre of the same box say nothing about which knockout each of them
  /// uses. See [CablingOverrides.endAnchors].
  void setCablingEndAnchor(String bundleId, bool atStart, Offset? fraction) {
    if (bundleId.isEmpty) return;
    final key = cablingEndKey(bundleId, atStart);
    _pushAvUndo(
      fraction == null ? 'Centre a run on its box' : 'Move where a run lands',
      _cablingScope,
    );
    if (fraction == null) {
      avCabling.endAnchors.remove(key);
    } else {
      avCabling.endAnchors[key] = Offset(
        fraction.dx.clamp(0.0, 1.0),
        fraction.dy.clamp(0.0, 1.0),
      );
    }
    notifyListeners();
  }

  /// Takes ONE run's caption off the drawings, or puts it back.
  ///
  /// A sheet regularly carries a run that needs no label — the obvious one, the
  /// one named in the title block, the one whose caption sits over the detail
  /// the sheet is being issued for. Turning every caption off is a different
  /// decision and a much worse one.
  void setCablingLabelHidden(String edgeKey, bool hidden) {
    if (edgeKey.isEmpty) return;
    if (avCabling.hiddenLabels.contains(edgeKey) == hidden) return;
    _pushAvUndo(hidden ? 'Hide a label' : 'Show a label', _cablingScope);
    if (hidden) {
      avCabling.hiddenLabels.add(edgeKey);
    } else {
      avCabling.hiddenLabels.remove(edgeKey);
    }
    notifyListeners();
  }

  /// Puts every hidden caption back. Returns how many came back, so the page
  /// can say so rather than appearing to do nothing.
  int showAllCablingLabels() {
    final count = avCabling.hiddenLabels.length;
    if (count == 0) return 0;
    _pushAvUndo('Show every label', _cablingScope);
    avCabling.hiddenLabels.clear();
    notifyListeners();
    return count;
  }

  /// True when some run of [colorKeys] carries a hand-picked colour, so the
  /// view can offer the way back out of one.
  bool hasCablingTypeColor(Iterable<String> colorKeys) =>
      colorKeys.any(avCabling.typeColors.containsKey);

  /// What a run lands on at one end — the jack, the plate, the patch panel.
  /// An empty string clears it, and prints nothing.
  void setCablingBundleEndLabel(
    String id, {
    String? fromLabel,
    String? toLabel,
  }) {
    _pushAvUndo('Label the end of a run', _cablingScope);
    void set(Map<String, String> into, String? value) {
      if (value == null) return;
      if (value.trim().isEmpty) {
        into.remove(id);
      } else {
        into[id] = value.trim();
      }
    }

    set(avCabling.fromLabels, fromLabel);
    set(avCabling.toLabels, toLabel);
    notifyListeners();
  }

  /// Takes an undo snapshot of the cabling drawing before a gesture that will
  /// write through it over and over. Dragging a bend writes on every pointer
  /// event, and one drag has to be one undo.
  void pushCablingUndo(String label) => _pushAvUndo(label, _cablingScope);

  /// Steers a run on the cabling drawing: the bends it passes through, in
  /// order. An empty list hands it back to the router.
  ///
  /// [recordUndo] false is for the middle of a drag — one drag is one undo,
  /// not one per pointer event. The caller takes the snapshot when the drag
  /// starts, the same bargain the signal flow's bends make.
  void setCablingBundleWaypoints(
    String id,
    List<Offset> points, {
    bool recordUndo = true,
  }) {
    if (recordUndo) _pushAvUndo('Route a run', _cablingScope);
    if (points.isEmpty) {
      avCabling.waypoints.remove(id);
    } else {
      avCabling.waypoints[id] = List<Offset>.from(points);
    }
    notifyListeners();
  }

  /// Takes something off the drawing. A derived box or run is HIDDEN rather
  /// than deleted, because deleting one would only bring it back next time the
  /// drawing was built.
  void removeCablingItem(String id) {
    _pushAvUndo('Remove from the cabling drawing', _cablingScope);
    if (id.startsWith('box:')) {
      avCabling.extraBoxes.removeWhere((b) => b.id == id);
      avCabling.extraBundles.removeWhere(
        (b) => b.fromBoxId == id || b.toBoxId == id,
      );
    } else if (id.startsWith('run:')) {
      avCabling.extraBundles.removeWhere((b) => b.id == id);
    } else {
      avCabling.hidden.add(id);
    }
    avCabling.positions.remove(id);
    avCabling.labels.remove(id);
    avCabling.bodies.remove(id);
    avCabling.counts.remove(id);
    avCabling.cableTypes.remove(id);
    avCabling.colors.remove(id);
    avCabling.fromLabels.remove(id);
    avCabling.toLabels.remove(id);
    avCabling.waypoints.remove(id);
    notifyListeners();
  }

  /// Puts a hidden derived item back.
  void restoreCablingItem(String id) {
    if (!avCabling.hidden.remove(id)) return;
    _pushAvUndo('Restore to the cabling drawing', _cablingScope);
    notifyListeners();
  }

  /// Drops a new box on the cabling drawing.
  ///
  /// [occupied] is what is already on the sheet — the caller has the drawing to
  /// hand, and only the drawing knows, because the DERIVED boxes are rebuilt
  /// from the room every time and are not in [CablingOverrides] to be counted.
  /// Without it a hand-added location took the slot the first location off the
  /// floor plan was already sitting in, and the two drew on top of each other.
  CablingBox addCablingBox({
    required CablingBoxKind kind,
    String label = '',
    Offset? pos,
    String body = '',
    String shape = '',
    List<Rect> occupied = const [],
  }) {
    _pushAvUndo('Add ${kCablingBoxKindLabels[kind]?.toLowerCase() ?? 'box'}', _cablingScope);
    _avCablingBoxCounter++;
    // The slot the derived layout would have given it, stepped on by how many
    // of the SAME kind are already drawn. Counting all boxes instead would put
    // a pathway on top of the device added a moment earlier, since the two
    // belong in completely different parts of the sheet.
    final wanted = pos ??
        defaultCablingBoxPosition(
          avCabling.extraBoxes.where((b) => b.kind == kind).length,
          kind,
        );
    final size = CablingBox(id: '', label: '', kind: kind, body: body).size;
    final box = CablingBox(
      id: 'box:$_avCablingBoxCounter',
      label: label.trim().isEmpty
          ? _defaultCablingBoxLabel(kind, shape)
          : label.trim(),
      kind: kind,
      // An explicit position is somebody saying where they want it and is left
      // alone; a slot picked by the layout is only a guess and gets moved off
      // whatever is already there.
      pos: pos != null
          ? wanted
          : nonOverlappingPosition(
              desired: wanted,
              size: size,
              others: occupied,
            ),
      body: body,
      shape: shape,
    );
    avCabling.extraBoxes.add(box);
    notifyListeners();
    return box;
  }

  /// What a new box is called before anybody renames it. A device takes the
  /// name of the shape it was picked from — "Ceiling mic", not "Device" — and
  /// a pathway is named for what it actually is, since it is drawn once per
  /// room and always means the same thing.
  static String _defaultCablingBoxLabel(CablingBoxKind kind, String shape) {
    if (kind == CablingBoxKind.device) {
      return kCablingDeviceShapes[shape]?.label ?? 'Device';
    }
    if (kind == CablingBoxKind.pathway) return 'Network Pathway back to TR';
    return kCablingBoxKindLabels[kind] ?? 'Box';
  }

  /// Swaps which icon a device box draws.
  void setCablingBoxShape(String id, String shape) {
    final at = avCabling.extraBoxes.indexWhere((b) => b.id == id);
    if (at < 0) return;
    _pushAvUndo('Change the device', _cablingScope);
    avCabling.extraBoxes[at] = avCabling.extraBoxes[at].copyWith(shape: shape);
    notifyListeners();
  }

  /// A run the room cannot know about — a spare conduit, somebody else's
  /// contract, a pull string.
  CablingBundle? addCablingBundle({
    required String fromBoxId,
    required String toBoxId,
    double count = 1,
    String cableType = '',
    int color = 0xFFD32F2F,
  }) {
    if (fromBoxId.isEmpty || toBoxId.isEmpty || fromBoxId == toBoxId) {
      return null;
    }
    _pushAvUndo('Add cable run', _cablingScope);
    _avCablingRunCounter++;
    final bundle = CablingBundle(
      id: 'run:$_avCablingRunCounter',
      fromBoxId: fromBoxId,
      toBoxId: toBoxId,
      count: count,
      cableType: cableType,
      color: color,
    );
    avCabling.extraBundles.add(bundle);
    notifyListeners();
    return bundle;
  }

  void updateCablingBundle(CablingBundle bundle) {
    final at = avCabling.extraBundles.indexWhere((b) => b.id == bundle.id);
    if (at < 0) return;
    _pushAvUndo('Edit cable run', _cablingScope);
    avCabling.extraBundles[at] = bundle;
    notifyListeners();
  }

  /// Throws away every edit and goes back to what the room says.
  void resetCablingSchematic() {
    _pushAvUndo('Reset the cabling drawing', _cablingScope);
    avCabling.clear();
    notifyListeners();
  }

  // --- notation on a sheet --------------------------------------------------

  /// Counter behind annotation ids ('NOTE_7'). Shared across sheets so an id
  /// stays unique when notation is copied from one to another.
  int _avAnnotationCounter = 0;

  /// Adds notation to [planId]. Returns it, or null when the sheet is gone.
  PlanAnnotation? addAvAnnotation(String planId, PlanAnnotation note) {
    final index = avFloorPlans.indexWhere((p) => p.id == planId);
    if (index < 0) return null;
    _pushAvUndo('Add ${kPlanShapeLabels[note.shape]?.toLowerCase() ?? 'note'}', _plansScope);
    final plan = avFloorPlans[index];
    final taken = {for (final a in plan.annotations) a.id};
    String id = note.id;
    if (id.isEmpty || taken.contains(id)) {
      do {
        _avAnnotationCounter++;
        id = 'NOTE_$_avAnnotationCounter';
      } while (taken.contains(id));
    }
    final stored = note.withId(id);
    avFloorPlans[index] = plan.copyWith(
      annotations: [...plan.annotations, stored],
    );
    notifyListeners();
    return stored;
  }

  /// [recordUndo] is false while a drag is in flight: one undo entry for the
  /// move, not one per pointer event.
  void updateAvAnnotation(
    String planId,
    PlanAnnotation note, {
    bool recordUndo = true,
  }) {
    final index = avFloorPlans.indexWhere((p) => p.id == planId);
    if (index < 0) return;
    final plan = avFloorPlans[index];
    final at = plan.annotations.indexWhere((a) => a.id == note.id);
    if (at < 0) return;
    if (recordUndo) _pushAvUndo('Edit notation', _plansScope);
    final next = List<PlanAnnotation>.from(plan.annotations);
    next[at] = note;
    avFloorPlans[index] = plan.copyWith(annotations: next);
    notifyListeners();
  }

  void removeAvAnnotation(String planId, String noteId) {
    final index = avFloorPlans.indexWhere((p) => p.id == planId);
    if (index < 0) return;
    _pushAvUndo('Remove notation', _plansScope);
    final plan = avFloorPlans[index];
    avFloorPlans[index] = plan.copyWith(
      annotations: [
        for (final a in plan.annotations)
          if (a.id != noteId) a,
      ],
    );
    notifyListeners();
  }

  /// The next unused callout tag on [planId] — '1', '2', … so adding one does
  /// not start by asking the user to remember what the last number was.
  String nextCalloutTag(String planId) {
    final plan = avFloorPlanById(planId);
    final used = {
      for (final c in plan?.callouts ?? const <FloorPlanCallout>[])
        c.tag.trim(),
    };
    for (int n = 1; n < 500; n++) {
      if (!used.contains('$n')) return '$n';
    }
    return '';
  }

  /// Copies [sourcePath] in beside the working config and returns the file
  /// name to store on the plan — or the absolute path unchanged when there is
  /// nowhere to copy it to (no config saved yet) or the copy failed.
  ///
  /// Copying rather than linking is the point: a room folder is the unit that
  /// gets zipped and mailed, and a plan referenced off somebody's desktop is a
  /// broken image the moment it leaves this machine. Falling back to the
  /// original path rather than failing keeps an unsaved room usable — the plan
  /// is imported on the next save, when there is a folder to put it in.
  Future<String> importFloorPlanImage(String sourcePath) =>
      importRoomImage(sourcePath, 'floorplan');

  /// The same copy-in for any picture the room refers to by name — the plan
  /// sheets, and the signal flow's backdrop. [kind] is the middle of the file
  /// name, so a folder full of them still says what each one is.
  Future<String> importRoomImage(String sourcePath, String kind) async {
    if (currentConfigPath.isEmpty) return sourcePath;
    try {
      final dir = path.dirname(currentConfigPath);
      final stem = path.basenameWithoutExtension(currentConfigPath);
      final ext = path.extension(sourcePath);
      // Numbered so importing a second one doesn't overwrite the first.
      String name = '${stem}_$kind$ext';
      int n = 1;
      while (File(path.join(dir, name)).existsSync()) {
        n++;
        name = '${stem}_$kind$n$ext';
      }
      await File(sourcePath).copy(path.join(dir, name));
      AppLogger.logInfo('Image copied in as $name.');
      return name;
    } catch (e, stack) {
      AppLogger.logError('Could not copy the image in', e, stack);
      return sourcePath;
    }
  }

  /// Where a floor plan image is resolved from: an absolute path as given,
  /// otherwise beside the working config, which is where the importer puts it.
  String resolveFloorPlanImage(String imageFile) {
    if (imageFile.trim().isEmpty) return '';
    if (path.isAbsolute(imageFile)) return imageFile;
    final dir = currentConfigPath.isEmpty
        ? effectiveRootFolder
        : path.dirname(currentConfigPath);
    return path.join(dir, imageFile);
  }

  // --- room type presets ----------------------------------------------------

  /// The folder presets are read from and written to.
  String get roomPresetFolder =>
      path.join(effectiveRootFolder, kRoomPresetFolder);

  /// Every preset on disk, with the four built-ins written out first if the
  /// folder has never been used.
  /// Writes the building code and room number into the open room.
  ///
  /// The two fields the Wizard asks for first, set from somewhere other than
  /// the Wizard - which is what building a room from a line item needs, since
  /// the line already says which room it is. Blank values are left alone
  /// rather than written as blanks: a name that could not be read is not a
  /// reason to clear one that was already there.
  void setRoomIdentity({String building = '', String room = ''}) {
    final setup = roomConfig['SYSTEM_SETUP'];
    if (setup is! Map) return;
    if (building.trim().isNotEmpty) setup['gve_bldg'] = building.trim();
    if (room.trim().isNotEmpty) setup['gve_room'] = room.trim();
    // The full room name is generated from the two, the same way the Wizard
    // generates it - so a room built this way is named like every other.
    updateFullRoomName();
  }

  /// The room type on the master refresh sheet called [sourceName], or null.
  ///
  /// How a LINE ITEM finds the preset it was priced from - see
  /// [ManualRoom.sourceType] and [RoomPreset.sourceName]. Matched on the
  /// sheet's own name rather than on the picker's, because the picker's names
  /// are written out for a reader and are meant to be able to change.
  ///
  /// Falls back to the preset's display name, so a room type somebody has
  /// since drawn by hand - with no sheet behind it - can still be found by
  /// what it is called.
  RoomPreset? presetForSourceName(String sourceName) {
    final wanted = sourceName.trim().toLowerCase();
    if (wanted.isEmpty) return null;
    final presets = availableRoomPresets();
    for (final preset in presets) {
      if (preset.sourceName.trim().toLowerCase() == wanted) return preset;
    }
    for (final preset in presets) {
      if (preset.name.trim().toLowerCase() == wanted) return preset;
    }
    return null;
  }

  List<RoomPreset> availableRoomPresets() {
    ensureBuiltInRoomPresets(effectiveRootFolder);
    return loadRoomPresets(effectiveRootFolder);
  }

  /// Stamps [preset] into the current room.
  ///
  /// Everything gets FRESH ids: a preset's `AVNODE_1` is a placeholder, and
  /// applying two presets — or a preset into a room that already has gear —
  /// must not have the second silently take the first's boxes. The cables and
  /// rack slots are remapped through the same table, so a preset's wiring
  /// survives the renumbering intact.
  ///
  /// [jackPrefix] renumbers the preset's jacks into this room's scheme. Left
  /// blank, the preset's own numbering is used as written — which is right
  /// when somebody has saved a preset FOR a specific building.
  ///
  /// Returns a short summary of what landed, for the message afterwards.
  ({int devices, int jacks, int cables, int racks, int locations})
  applyRoomPreset(RoomPreset preset, {String jackPrefix = ''}) {
    _pushAvUndo('Apply ${preset.name}', const {
      AvUndoScope.flow,
      AvUndoScope.racks,
      AvUndoScope.floorPlans,
      AvUndoScope.cabling,
    });

    // --- locations first: the nodes reference them ---------------------------
    final locationMap = <String, String>{};
    for (final location in preset.locations) {
      // A location with the same name already in the room is REUSED rather
      // than duplicated. Two entries called "Ceiling" is the fastest way to
      // make every per-location count meaningless, and applying a preset to a
      // room that already has locations is the normal case, not the odd one.
      final existing = avLocations
          .where(
            (l) =>
                l.name.trim().toLowerCase() ==
                location.name.trim().toLowerCase(),
          )
          .firstOrNull;
      if (existing != null) {
        locationMap[location.id] = existing.id;
        continue;
      }
      final stored = addAvLocation(
        RoomLocation(
          id: '',
          name: location.name,
          zone: location.zone,
          callout: location.callout,
          note: location.note,
        ),
      );
      locationMap[location.id] = stored.id;
    }

    // --- devices and jack fields ---------------------------------------------
    final nodeMap = <String, String>{};
    // Where to drop the preset so it doesn't land on top of whatever is
    // already drawn.
    double offsetY = 0;
    for (final n in avNodes) {
      offsetY = math.max(offsetY, n.pos.dy + n.height + 60);
    }

    for (final node in preset.nodes) {
      final relocated = node.copyWith(
        pos: Offset(node.pos.dx, node.pos.dy + offsetY),
        locationId: locationMap[node.locationId] ?? kNoLocationId,
        ports: node.isJackField && jackPrefix.isNotEmpty
            ? _renumberedJacks(node.ports, preset.jackPrefix, jackPrefix)
            : node.ports,
      );
      // addAvNode re-keys anything whose id is taken, which is what makes
      // applying a preset twice give eight jacks rather than four.
      final stored = addAvNode(relocated, recordUndo: false);
      nodeMap[node.id] = stored.id;
    }

    // --- cables, remapped onto the stored ids --------------------------------
    int cables = 0;
    for (final cable in preset.cables) {
      final from = nodeMap[cable.fromNodeId];
      final to = nodeMap[cable.toNodeId];
      if (from == null || to == null) continue;
      final added = addAvCable(
        fromNodeId: from,
        fromPortId: cable.fromPortId,
        toNodeId: to,
        toPortId: cable.toPortId,
        signal: cable.signal,
        label: cable.label,
        recordUndo: false,
      );
      if (added != null) cables++;
    }

    // --- racks, their hardware, and who sits where ---------------------------
    final rackMap = <String, String>{};
    for (final rack in preset.racks) {
      final stored = addAvRack(rack.name, rack.heightU, kind: rack.kind);
      rackMap[rack.id] = stored.id;
    }
    for (final item in preset.rackItems) {
      final stored = addAvRackItem(item.withId(''));
      if (stored != null) nodeMap[item.id] = stored.id;
    }
    preset.rackSlots.forEach((occupantId, slot) {
      final occupant = nodeMap[occupantId];
      final rack = rackMap[slot.rackId];
      if (occupant == null || rack == null) return;
      avRackSlots[occupant] = slot.copyWith(rackId: rack);
    });

    for (final s in preset.screenSwitches) {
      addAvScreenSwitch(
        s.copyWith(
          startLocationId: locationMap[s.startLocationId] ?? kNoLocationId,
          endLocationId: locationMap[s.endLocationId] ?? kNoLocationId,
        ).withId(''),
      );
    }

    AppLogger.logInfo(
      'Applied the "${preset.name}" room type: ${preset.nodes.length} boxes, '
      '$cables cables, ${preset.racks.length} racks.',
    );

    // --- the sheets the room lays out on -------------------------------------
    //  Blank paper, with this room type's locations already placed on it. The
    //  markers are keyed by the PRESET's location ids, which are not the ids
    //  this room gave those locations — a room that already had a "Ceiling"
    //  reused its own — so every key goes through the same map the nodes did.
    //  A marker whose location did not come across is dropped rather than left
    //  pointing at an id nothing answers to.
    //
    //  Never replaces a sheet the room already has: an imported drawing is a
    //  fact about the building and a preset has no business overwriting one.
    for (final sheet in preset.floorPlans) {
      final already = avFloorPlans.any(
        (p) => p.name.trim().toLowerCase() == sheet.name.trim().toLowerCase(),
      );
      if (already) continue;
      addAvFloorPlan(
        sheet.withId('').copyWith(
          markers: {
            for (final entry in sheet.markers.entries)
              if (locationMap[entry.key] != null)
                locationMap[entry.key]!: entry.value,
          },
        ),
      );
    }

    notifyListeners();

    return (
      devices: preset.deviceCount,
      jacks: preset.jackCount,
      cables: cables,
      racks: preset.racks.length,
      locations: locationMap.length,
    );
  }

  /// Writes [preset]'s SYSTEM_SETUP values into the room, and returns how many
  /// keys it set.
  ///
  /// These OVERWRITE what is there, which is the opposite of how the rest of
  /// the preset behaves and is deliberate. The template config ships a
  /// demonstration room's numbers in every I/O field — `input_pc` is 1,
  /// `output_proj_1` is 5B — so "only fill what is blank" would fill nothing
  /// and leave the room pointing at a switcher nobody wired. A preset that
  /// draws the PC into HDMI IN 3 is a better answer than the template's, and
  /// it is the only one that agrees with the drawing.
  ///
  /// The one thing it will not do is resurrect a key: a blank in the preset
  /// clears a value the room has, but a key the room has already pruned away
  /// (a camera input in a room with no cameras) stays gone.
  ///
  /// Run this AFTER the control-side prefill. The prefill sets the hardware
  /// counts, and both the family key restore and the source-input tidy below
  /// read those counts to decide what this room is entitled to.
  int applyPresetSystemSetup(RoomPreset preset) {
    final setup = roomConfig['SYSTEM_SETUP'];
    if (setup is! Map || preset.systemSetup.isEmpty) return 0;

    // Hardware the prefill just put in the room gets its own settings back
    // first, so a preset value written below always wins over a restored one.
    for (final spec in uiSchema.deviceTypes) {
      final raw = setup[spec.countKey]?.toString() ?? '';
      final count = raw.toLowerCase() == 'yes' ? 1 : (int.tryParse(raw) ?? 0);
      _restoreSystemKeysForCount(spec.countKey, count);
    }

    final written = <String>[];
    preset.systemSetup.forEach((key, value) {
      if (value.isEmpty && !setup.containsKey(key)) return;
      if (setup[key]?.toString() == value) return;
      setup[key] = value;
      written.add(key);
    });

    // The source list and the camera count are both settled now, so the
    // input_* keys this room has no source for can go — including any the
    // preset itself has just written, which is the right answer: a preset
    // that names an input the panel draws no button for is wrong about it.
    pruneUnusedSourceInputs();

    if (written.isNotEmpty) {
      AppLogger.logInfo(
        'The "${preset.name}" room type set ${written.length} system '
        'setting(s): ${written.join(', ')}.',
      );
    }
    notifyListeners();
    return written.length;
  }

  /// A preset's jack labels under this room's prefix.
  ///
  /// The preset writes 'RM01'; a room numbered 1110 wants '111001'. Only the
  /// leading prefix is swapped — the position number and its padding are the
  /// preset's design and stay exactly as saved.
  List<AvPort> _renumberedJacks(
    List<AvPort> ports,
    String from,
    String to,
  ) => [
    for (final p in ports)
      p.copyWith(
        label: from.isNotEmpty && p.label.startsWith(from)
            ? '$to${p.label.substring(from.length)}'
            : p.label,
      ),
  ];

  /// The current room as a reusable room type.
  ///
  /// Deliberately drops the cost estimate, the floor plan and the room's
  /// identity: a negotiated price belongs to a job, a drawing belongs to a
  /// building, and a preset that carried "Bessey 103" into every room built
  /// from it would be a preset nobody could use twice.
  ///
  /// The switcher I/O map and the source layout DO come along — see
  /// [presetSystemSetupFrom]. They are decided by how this type of room is
  /// wired, and a preset that brought the gear and the cabling but left the
  /// input numbers behind would still leave somebody reading them off the
  /// drawing and typing them in.
  RoomPreset currentRoomAsPreset({
    required String name,
    String description = '',
  }) {
    final jackPrefix = _dominantJackPrefix();
    final setup = roomConfig['SYSTEM_SETUP'];
    return RoomPreset(
      name: name,
      description: description,
      jackPrefix: jackPrefix,
      systemSetup: setup is Map ? presetSystemSetupFrom(setup) : const {},
      locations: List<RoomLocation>.from(avLocations),
      // The markers go: they are positions on a plan this preset does not
      // carry, and a location that claims to be placed with no plan behind it
      // reads as a bug on the Floor Plan tab.
      nodes: [for (final n in avNodes) n],
      cables: List<AvCable>.from(avCables),
      racks: List<RackFrame>.from(avRacks),
      rackItems: List<RackItem>.from(avRackItems),
      rackSlots: Map<String, RackSlot>.from(avRackSlots),
      screenSwitches: List<ScreenSwitch>.from(avScreenSwitches),
    );
  }

  /// The prefix this room's jacks share, so a preset saved from it can be
  /// renumbered into another room. '' when there isn't one, which correctly
  /// means "don't try to renumber these".
  ///
  /// The room NUMBER is asked first, because from the labels alone there is no
  /// way to tell where the prefix ends: '111001'..'111003' share the leading
  /// '11100', and only the room knows that '1110' is the part that changes
  /// room to room and '01' is the jack. When the room's number is what the
  /// jacks are actually numbered with, that is the answer. Only a room with no
  /// number falls back to the shared-run guess, which then has to drop the
  /// trailing digits because it cannot tell them from the numbering.
  String _dominantJackPrefix() {
    final labels = [
      for (final n in avNodes)
        if (n.isJackField)
          for (final p in n.ports) p.label.trim(),
    ].where((l) => l.isNotEmpty).toList();
    if (labels.isEmpty) return '';

    final setup = roomConfig['SYSTEM_SETUP'];
    final roomNumber = ((setup is Map ? setup['gve_room']?.toString() : null) ??
            '')
        .replaceAll(RegExp(r'[^0-9]'), '');
    if (roomNumber.isNotEmpty &&
        labels.every((l) => l.startsWith(roomNumber))) {
      return roomNumber;
    }

    // The longest leading run every label shares.
    String prefix = labels.first;
    for (final label in labels) {
      int i = 0;
      while (i < prefix.length && i < label.length && prefix[i] == label[i]) {
        i++;
      }
      prefix = prefix.substring(0, i);
      if (prefix.isEmpty) return '';
    }
    // Trailing digits shared by every label could belong to either side, and
    // guessing wrong renumbers the room to nonsense. Dropped, so 'AV-01' gives
    // 'AV-' and a purely numeric scheme with no room number gives nothing.
    return prefix.replaceAll(RegExp(r'\d+$'), '');
  }

  /// Config device keys the user deliberately removed from the canvas, so
  /// re-seeding doesn't keep dragging them back.
  final Set<String> avDismissedDevices = {};

  /// The config the automatic routing pass was last run against, as a
  /// fingerprint of everything that pass reads — see [routingFingerprint].
  ///
  /// THE DRAWING IS A DOCUMENT, NOT A VIEW. Once the room has been converted
  /// and the cables are on the canvas, opening the tab again should show the
  /// diagram exactly as it was left: boxes where they were dragged, cables
  /// where they were drawn. The automatic pass used to run on every visit, so
  /// a catalog revision or a change of mind about which connector a tie lands
  /// on could quietly redraw a room nobody had touched.
  ///
  /// Empty means it has never run — an older room, or one just converted —
  /// and the pass runs once and records what it read. After that it only runs
  /// again when this stops matching the config, which is exactly when a device
  /// or one of the routing values has been edited.
  String avRoutedFingerprint = '';

  /// Per-room overrides of the signal-type palette. Recoloring HDMI here
  /// moves every HDMI cable, every HDMI port dot and the legend entry
  /// together — the point being that the key keeps describing the drawing.
  /// Empty means the built-in colors.
  final Map<SignalType, Color> avSignalColors = {};

  /// This room's cost estimate: tax, percentage fees, per-room prices and any
  /// non-device lines. Stored with the diagram it prices — a negotiated price
  /// is a fact about the job, not about the model — see the Cost page on the
  /// AV Flow tab.
  final RoomCostSettings avCost = RoomCostSettings();

  /// Counter behind fee and line-item ids.
  int _avCostCounter = 0;

  String _nextCostId(String prefix) {
    _avCostCounter++;
    return '$prefix$_avCostCounter';
  }

  // --- cost estimate edits (each one notifies; the page rebuilds off state) --

  void setAvCostTax({double? percent, String? label, String? currency}) {
    if (percent != null) avCost.taxPercent = math.max(0, percent);
    if (label != null) avCost.taxLabel = label;
    if (currency != null && currency.isNotEmpty) avCost.currency = currency;
    notifyListeners();
  }

  CostFee addAvCostFee({String name = 'Fee', double percent = 0}) {
    final fee = CostFee(id: _nextCostId('FEE_'), name: name, percent: percent);
    avCost.fees.add(fee);
    notifyListeners();
    return fee;
  }

  void updateAvCostFee(CostFee fee) {
    final index = avCost.fees.indexWhere((f) => f.id == fee.id);
    if (index < 0) return;
    avCost.fees[index] = fee;
    notifyListeners();
  }

  void removeAvCostFee(String feeId) {
    avCost.fees.removeWhere((f) => f.id == feeId);
    notifyListeners();
  }

  /// Sets this room's price for one estimate line, or clears it back to the
  /// catalog price when [price] is null.
  void setAvCostPrice(String lineKey, double? price) {
    if (price == null) {
      avCost.priceOverrides.remove(lineKey);
    } else {
      avCost.priceOverrides[lineKey] = price;
    }
    notifyListeners();
  }

  CostLineItem addAvCostItem({
    String description = '',
    String category = '',
    double qty = 1,
    double unitPrice = 0,
    bool taxable = true,
    String catalogModel = '',
  }) {
    final item = CostLineItem(
      id: _nextCostId('ITEM_'),
      description: description,
      category: category,
      qty: qty,
      unitPrice: unitPrice,
      taxable: taxable,
      catalogModel: catalogModel,
    );
    avCost.items.add(item);
    notifyListeners();
    return item;
  }

  void updateAvCostItem(CostLineItem item) {
    final index = avCost.items.indexWhere((i) => i.id == item.id);
    if (index < 0) return;
    avCost.items[index] = item;
    notifyListeners();
  }

  void removeAvCostItem(String itemId) {
    avCost.items.removeWhere((i) => i.id == itemId);
    notifyListeners();
  }

  // --- parts bought for the job but not on the drawing ----------------------
  //  A box nobody drew, a spare shelf, a box of blanks, a spool of cable.
  //  These belong ON the equipment, hardware and cabling lines rather than in
  //  "Other items", because that is where somebody reading the quote looks for
  //  them — and because they are priced from the catalog like everything else.

  /// Equipment on the quote that is not on the diagram. [catalogModel] empty
  /// makes it a plain line: whatever it is called, at whatever price gets
  /// typed on it.
  CostLineItem addAvCostExtraEquipment({
    String catalogModel = '',
    String description = '',
    String category = '',
    double qty = 1,
    double unitPrice = 0,
  }) {
    final item = CostLineItem(
      id: _nextCostId('EQP_'),
      description: description,
      category: category,
      qty: qty,
      unitPrice: unitPrice,
      catalogModel: catalogModel,
    );
    avCost.extraEquipment.add(item);
    notifyListeners();
    return item;
  }

  void updateAvCostExtraEquipment(CostLineItem item) {
    final index = avCost.extraEquipment.indexWhere((i) => i.id == item.id);
    if (index < 0) return;
    avCost.extraEquipment[index] = item;
    notifyListeners();
  }

  void removeAvCostExtraEquipment(String itemId) {
    avCost.extraEquipment.removeWhere((i) => i.id == itemId);
    avCost.priceOverrides.remove(itemId);
    notifyListeners();
  }

  /// Turns a quoted-but-undrawn equipment line into real devices on the
  /// diagram, one per unit, and drops the cost line.
  ///
  /// Dropping the line is the point, not a side effect: the diagram is priced,
  /// so leaving both would quote the room twice for the same box. Any price
  /// typed on the line moves across to the devices' line key, because a
  /// negotiated figure is about the gear, not about which list it was on.
  ///
  /// Returns the nodes added.
  List<AvNode> promoteAvCostEquipmentToDiagram(
    String itemId, {
    required Offset at,
  }) {
    final item = avCost.extraEquipment
        .where((i) => i.id == itemId)
        .firstOrNull;
    if (item == null) return const [];
    final template = avDeviceLibrary.templateForModel(item.catalogModel);
    if (template == null) return const [];

    final typed = avCost.priceOverrides[item.id];
    final count = item.qty < 1 ? 1 : item.qty.round();
    final label = item.description.trim().isEmpty
        ? template.model
        : item.description.trim();

    final added = <AvNode>[];
    for (int i = 0; i < count; i++) {
      added.add(
        addAvNode(
          AvNode(
            id: '',
            label: count == 1 ? label : '$label ${i + 1}',
            model: template.model,
            pos: Offset(at.dx, at.dy + i * 140),
            ports: withPowerInlet(template.ports, template.powerInput),
            rackUnits: template.rackUnits,
            powerWatts: template.powerWatts,
            btuPerHour: template.btuPerHour,
            powerSource: powerSourceForInput(template.powerInput),
          ),
        ),
      );
    }

    removeAvCostExtraEquipment(item.id);
    // Devices group by model on the estimate — the key the diagram will price
    // them under, and where the typed figure has to land to survive.
    if (typed != null && template.model.trim().isNotEmpty) {
      avCost.priceOverrides['model:${template.model.trim().toLowerCase()}'] =
          typed;
    }
    notifyListeners();
    return added;
  }

  /// Turns a quoted-but-unplaced rack part into real rack hardware, one per
  /// unit, left out of any frame so the Racks tab lists it as waiting to be
  /// placed. Same trade as [promoteAvCostEquipmentToDiagram]: the cost line
  /// goes, because placed hardware is priced off the rack.
  List<RackItem> promoteAvCostHardwareToRacks(String itemId) {
    final item = avCost.extraHardware.where((i) => i.id == itemId).firstOrNull;
    if (item == null) return const [];
    final template = avDeviceLibrary.templateForModel(item.catalogModel);
    if (template == null) return const [];

    final typed = avCost.priceOverrides[item.id];
    final count = item.qty < 1 ? 1 : item.qty.round();
    final label = item.description.trim().isEmpty
        ? template.model
        : item.description.trim();

    final added = <RackItem>[];
    for (int i = 0; i < count; i++) {
      final placed = addAvRackItem(
        RackItem(
          id: '',
          catalogModel: template.model,
          label: label,
          category: template.category,
          partNumber: template.partNumber,
          rackUnits: math.max(1, template.rackUnits),
          price: typed ?? template.priceForTier(pricingTier).price,
        ),
      );
      if (placed != null) added.add(placed);
    }

    removeAvCostExtraHardware(item.id);
    notifyListeners();
    return added;
  }

  /// Forgets a rack placement that nothing can draw — the frame it names is
  /// gone, or its occupant is. Whatever was in it goes back to the Racks tab's
  /// "to place" list instead of being invisible in both places at once.
  void clearAvRackPlacement(String occupantId) {
    if (!avRackSlots.containsKey(occupantId)) return;
    _pushAvUndo('Un-rack ${rackOccupantLabel(occupantId)}', _racksScope);
    avRackSlots.remove(occupantId);
    notifyListeners();
  }

  CostLineItem addAvCostExtraHardware({
    String catalogModel = '',
    String description = '',
    String category = '',
    double qty = 1,
    double unitPrice = 0,
  }) {
    final item = CostLineItem(
      id: _nextCostId('HW_'),
      description: description,
      category: category,
      qty: qty,
      unitPrice: unitPrice,
      catalogModel: catalogModel,
    );
    avCost.extraHardware.add(item);
    notifyListeners();
    return item;
  }

  void updateAvCostExtraHardware(CostLineItem item) {
    final index = avCost.extraHardware.indexWhere((i) => i.id == item.id);
    if (index < 0) return;
    avCost.extraHardware[index] = item;
    notifyListeners();
  }

  void removeAvCostExtraHardware(String itemId) {
    avCost.extraHardware.removeWhere((i) => i.id == itemId);
    // A room price typed against a line that no longer exists would sit in the
    // sidecar forever, and reappear if the id were ever reused.
    avCost.priceOverrides.remove(itemId);
    notifyListeners();
  }

  CostLineItem addAvCostExtraCable({
    String catalogModel = '',
    String description = '',
    double qty = 1,
    double unitPrice = 0,
  }) {
    final item = CostLineItem(
      id: _nextCostId('CBL_'),
      description: description,
      category: kCategoryCable,
      qty: qty,
      unitPrice: unitPrice,
      catalogModel: catalogModel,
    );
    avCost.extraCables.add(item);
    notifyListeners();
    return item;
  }

  void updateAvCostExtraCable(CostLineItem item) {
    final index = avCost.extraCables.indexWhere((i) => i.id == item.id);
    if (index < 0) return;
    avCost.extraCables[index] = item;
    notifyListeners();
  }

  void removeAvCostExtraCable(String itemId) {
    avCost.extraCables.removeWhere((i) => i.id == itemId);
    avCost.priceOverrides.remove(itemId);
    notifyListeners();
  }

  // --- cabling: counted off the diagram, topped up by hand ------------------

  /// Whether the runs drawn on the AV flow are priced into the estimate.
  /// What order the equipment table lists its lines in. Kept with the estimate
  /// rather than with the window, so the screenshot, the workbook and the tab
  /// export all list the quote the way it was left.
  void setAvCostEquipmentSort(CostEquipmentSort value) {
    if (avCost.equipmentSort == value) return;
    avCost.equipmentSort = value;
    notifyListeners();
  }

  /// Buys every run of [signal] at [lengthFt] as [model] instead of whatever
  /// the catalog would have chosen. Empty [model] hands the choice back.
  ///
  /// Filed by length rather than by line key — see
  /// [RoomCostSettings.cableEntries] — because the line key is built out of
  /// the entry and moves when this changes.
  void setAvCableEntry(SignalType signal, double lengthFt, String model) {
    final key = cableEntryKey(signal, lengthFt);
    if (model.trim().isEmpty) {
      avCost.cableEntries.remove(key);
    } else {
      avCost.cableEntries[key] = model.trim();
    }
    notifyListeners();
  }

  /// Moves what this room typed against one cabling line onto another, for
  /// when a swap has renamed the line under it.
  ///
  /// Spares MOVE: "two spare 25 ft leads" is a decision about the order, and
  /// it survives a change of which lead is being ordered. The price does NOT —
  /// a figure typed against the old part was for the old part, which is the
  /// same rule the device swap follows.
  void moveAvCableLine({required String from, required String to}) {
    avCost.priceOverrides.remove(from);
    if (from == to) {
      notifyListeners();
      return;
    }
    final spares = avCost.cableSpares.remove(from);
    if (spares != null && spares > 0) {
      avCost.cableSpares[to] = (avCost.cableSpares[to] ?? 0) + spares;
    }
    notifyListeners();
  }

  void setAvCostIncludeCabling(bool value) {
    if (avCost.includeCabling == value) return;
    avCost.includeCabling = value;
    notifyListeners();
  }

  /// Extra runs to buy beyond what the diagram shows, against one cabling
  /// LINE — `cable:hdmi`, `cable:hdmi@50ft`. Per line rather than per signal
  /// type because a length is what gets ordered: two spare patch leads and
  /// two spare 50 ft runs are two decisions at two prices.
  ///
  /// 0 clears the entry rather than storing a zero, so the sidecar only
  /// records decisions somebody actually made.
  void setAvCableSpares(String lineKey, double qty) {
    if (qty <= 0) {
      avCost.cableSpares.remove(lineKey);
    } else {
      avCost.cableSpares[lineKey] = qty;
    }
    notifyListeners();
  }

  double avCableSpares(String lineKey) => avCost.cableSpares[lineKey] ?? 0;

  /// Units of one equipment line bought beyond the ones on the diagram — the
  /// cable spares box, for the boxes. See [RoomCostSettings.equipmentSpares].
  void setAvEquipmentSpares(String lineKey, double qty) {
    if (qty <= 0) {
      avCost.equipmentSpares.remove(lineKey);
    } else {
      avCost.equipmentSpares[lineKey] = qty;
    }
    notifyListeners();
  }

  double avEquipmentSpares(String lineKey) =>
      avCost.equipmentSpares[lineKey] ?? 0;

  /// Says who is furnishing one estimate line instead of this job, or clears
  /// it back to "this quote is buying it" when [source] is null.
  ///
  /// An empty [source] is a real answer — "by others", nobody named — so it is
  /// stored rather than treated as a clear. See [RoomCostSettings.furnishedLines].
  void setAvCostFurnished(String lineKey, String? source) {
    if (source == null) {
      if (avCost.furnishedLines.remove(lineKey) == null) return;
    } else {
      final trimmed = source.trim();
      if (avCost.furnishedLines[lineKey] == trimmed) return;
      avCost.furnishedLines[lineKey] = trimmed;
    }
    notifyListeners();
  }

  /// Who is furnishing [lineKey], or null when this job is buying it.
  String? avCostFurnishedBy(String lineKey) => avCost.furnishedLines[lineKey];

  /// The color a signal type is drawn in for this room.
  Color avSignalColor(SignalType s) => signalColor(s, avSignalColors);

  /// Recolors one signal type, or clears the override when [color] is null.
  void setAvSignalColor(SignalType s, Color? color) {
    if (color == null) {
      avSignalColors.remove(s);
    } else {
      avSignalColors[s] = color;
    }
    notifyListeners();
  }

  void resetAvSignalColors() {
    avSignalColors.clear();
    notifyListeners();
  }

  /// The config path the AV diagram belongs to (see [_schematicSyncedPath]).
  String _avFlowSyncedPath = ' never';

  /// Counter behind manually added node ids ('AVNODE_7').
  int _avNodeCounter = 0;

  /// Counter behind cable ids ('C7'), which double as the cable schedule's
  /// Cable ID column.
  int _avCableCounter = 0;

  AvNode? avNodeById(String id) {
    for (final n in avNodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// Adds a node, keeping ids unique. Returns the node actually stored (the
  /// caller may have passed an id that was already taken).
  /// [recordUndo] false is for a batch that has already taken its own snapshot
  /// — applying a room type adds twenty boxes, and twenty presses of Undo to
  /// get back to before it is not an undo anybody uses.
  AvNode addAvNode(AvNode node, {bool recordUndo = true}) {
    if (recordUndo) _pushAvUndo('Add ${node.label}', _flowScope);
    String id = node.id;
    if (id.isEmpty || avNodeById(id) != null) {
      do {
        _avNodeCounter++;
        id = 'AVNODE_$_avNodeCounter';
      } while (avNodeById(id) != null);
    }
    // withId rather than a rebuild here: the field list belongs next to the
    // fields, so a new one can't be quietly lost on the way in.
    final stored = node.withId(id);
    avNodes.add(stored);
    avDismissedDevices.remove(id);
    notifyListeners();
    return stored;
  }

  /// Replaces a node in place (drag, rename, port edit).
  ///
  /// [recordUndo] false is for a batch that has already taken its own
  /// snapshot — see [addAvNode].
  void updateAvNode(AvNode node, {bool recordUndo = true}) {
    final index = avNodes.indexWhere((n) => n.id == node.id);
    if (index < 0) return;
    if (recordUndo) _pushAvUndo('Edit ${node.label}', _flowScope);
    avNodes[index] = node;
    notifyListeners();
  }

  /// Records when the unit in one position went in, or takes the date off.
  ///
  /// Its own setter rather than a [updateAvNode] from the caller because the
  /// Lifecycle tab edits ONE field on a list of eleven boxes: a survey is
  /// eleven dates typed in a row, and each of them has to be its own undo
  /// entry named after the box it changed rather than a generic "Edit".
  void setAvNodeInstalledOn(String nodeId, DateTime? when) {
    final index = avNodes.indexWhere((n) => n.id == nodeId);
    if (index < 0) return;
    final node = avNodes[index];
    _pushAvUndo(
      when == null
          ? 'Clear install date on ${node.label}'
          : 'Install date on ${node.label}',
      _flowScope,
    );
    avNodes[index] = node.copyWith(
      installedOn: when == null
          ? null
          : DateTime(when.year, when.month, when.day),
      clearInstalledOn: when == null,
    );
    AppLogger.logInfo(
      when == null
          ? 'Install date cleared on ${node.label}.'
          : 'Install date on ${node.label} set to '
              '${formatEquipmentDate(when)}.',
    );
    notifyListeners();
  }

  /// Takes one position off the refresh cycle, or puts it back on.
  ///
  /// A bracket, a pole, a rack frame: they come out when the room is rebuilt
  /// and never on a schedule, so counting them among the things due in 2031 is
  /// inventing work — see [equipmentNeverReplaced].
  ///
  /// Off is [kNeverReplacedLife]; back on is 0, which is "nobody has said",
  /// NOT the number of years that was there before. A position with a life
  /// somebody typed has that life restored by the undo, which is the one path
  /// that can honestly bring it back.
  void setAvNodeNeverReplaced(String nodeId, bool never) {
    final index = avNodes.indexWhere((n) => n.id == nodeId);
    if (index < 0) return;
    final node = avNodes[index];
    if (equipmentNeverReplaced(node) == never) return;
    _pushAvUndo(
      never
          ? '${node.label} off the refresh cycle'
          : '${node.label} back on the refresh cycle',
      _flowScope,
    );
    avNodes[index] = node.copyWith(
      lifeYears: never ? kNeverReplacedLife : 0,
    );
    AppLogger.logInfo(
      never
          ? '${node.label} taken off the refresh cycle.'
          : '${node.label} put back on the refresh cycle.',
    );
    notifyListeners();
  }

  /// How long ONE position is held to, in years.
  ///
  /// The narrowest of the three rungs the plan reads - see
  /// [EquipmentLife.lifeYears]. Somebody looked at this projector, in this
  /// lecture theatre, running eight hours a day, and said five rather than the
  /// eight the product gets in general.
  ///
  /// 0 CLEARS IT rather than meaning "replace it immediately": zero years is
  /// not a life anybody types on purpose, and the field it is typed in is
  /// emptied far more often than it is set to nothing. A cleared position goes
  /// back to inheriting the catalog's figure, which is what it did before
  /// anybody touched it.
  ///
  /// A position that has been taken off the cycle entirely is left alone -
  /// [setAvNodeNeverReplaced] owns that sentinel, and a life typed over it
  /// would put a bracket back on the plan by a side door.
  void setAvNodeLifeYears(String nodeId, int years) {
    final index = avNodes.indexWhere((n) => n.id == nodeId);
    if (index < 0) return;
    final node = avNodes[index];
    if (node.lifeYears == kNeverReplacedLife) return;

    // Out of range reads as cleared, the same rule the catalog's own field
    // uses: a 600-year life would sit green on the plan for ever, which is the
    // one direction this must not be wrong in.
    final wanted = (years <= 0 || years > 100) ? 0 : years;
    if (node.lifeYears == wanted) return;

    _pushAvUndo(
      wanted == 0
          ? 'Life cleared on ${node.label}'
          : 'Life on ${node.label} set to $wanted yrs',
      _flowScope,
    );
    avNodes[index] = node.copyWith(lifeYears: wanted);
    AppLogger.logInfo(
      wanted == 0
          ? 'Life cleared on ${node.label}; it follows the catalog again.'
          : 'Life on ${node.label} set to $wanted years.',
    );
    notifyListeners();
  }

  /// Writes a life into the CATALOG, for every position of [model].
  ///
  /// THE OTHER HALF OF THE SAME EDIT. A life recorded on one position is a
  /// fact about that box in that room; a life recorded here is a fact about
  /// the PRODUCT, and it is the one worth keeping - it follows the model into
  /// every other room on the job and into next year's job, instead of being
  /// retyped in eleven places and drifting between them.
  ///
  /// Saved immediately, for the reason [setModelNeverControlled] is: the tab
  /// this is edited from has no Save button of its own, and an edit that lives
  /// in memory until something else happens to write the file is an edit
  /// somebody loses.
  ///
  /// Returns whether anything was written and the sentence to show.
  Future<({bool ok, String message})> setModelLifeYears(
    String model,
    int years,
  ) async {
    final name = model.trim();
    if (name.isEmpty) {
      return (
        ok: false,
        message: 'This position has no model on it, so there is no catalog '
            'entry to write a life onto. Give the device a model first.',
      );
    }

    final entry = avDeviceLibrary.templateForModel(name);
    if (entry == null) {
      // Not conjured here, for the same reason a never-controlled mark is not
      // - see [setModelNeverControlled]. An entry with a model and a life and
      // nothing else would shadow the real one when it was imported.
      return (
        ok: false,
        message: '"$name" is not in the catalog yet. Add it to the catalog '
            'first, then its life can be kept with it.',
      );
    }

    final wanted = (years <= 0 || years > 100) ? 0 : years;
    if (entry.lifeYears == wanted) {
      return (
        ok: true,
        message: wanted == 0
            ? '"$name" already carries no life in the catalog.'
            : '"$name" is already $wanted years in the catalog.',
      );
    }

    avDeviceLibrary.upsert(entry.copyWith(lifeYears: wanted));
    final file = await saveAvDeviceLibrary();
    // The catalog is a plain object rather than a listenable, so the pages
    // reading it have to be told.
    avDeviceLibraryChanged();

    AppLogger.logInfo(
      wanted == 0
          ? 'Catalog: life cleared on "$name".'
          : 'Catalog: "$name" set to $wanted years.',
    );

    final where = file.isEmpty
        ? ' (in memory only - the catalog file could not be written)'
        : ' and saved to $file';
    return (
      ok: file.isNotEmpty,
      message: wanted == 0
          ? 'Life cleared on "$name"$where.'
          : '"$name" set to $wanted years in the catalog$where.',
    );
  }

  /// How many boxes [setRoomInstalledOn] would touch, without touching any.
  ///
  /// Asked BEFORE the dialog commits, so the button can say "date 11 items"
  /// rather than "date the room" — a bulk edit that will not say how much it
  /// is about to change is one people press once and then stop trusting.
  int roomInstallDateCount({bool onlyUndated = false}) => avNodes
      .where(equipmentIsTracked)
      .where((n) => !onlyUndated || n.installedOn == null)
      .length;

  /// Dates every piece of equipment in the room at once. Returns how many
  /// changed.
  ///
  /// A ROOM IS USUALLY DATED ONCE, NOT ELEVEN TIMES. Everything in a room that
  /// was refreshed in 2018 went in that summer — one crew, one week — so the
  /// honest record and the fastest one are the same thing. Typing the same date
  /// into eleven rows is how a survey stops halfway through, and a half-dated
  /// room reads on the plan as a room with eleven unknowns.
  ///
  /// [onlyUndated] leaves anything already dated alone. That is the difference
  /// between finishing a survey and overwriting one: a room where somebody
  /// recorded the projector's real date last month and left the rest blank must
  /// not lose that date to a sweep of the room, so the caller has to choose.
  ///
  /// ONE UNDO ENTRY for the whole sweep, because it was one decision. Eleven
  /// entries would mean eleven presses of Undo to take back one press of Apply.
  int setRoomInstalledOn(DateTime? when, {bool onlyUndated = false}) {
    final day = when == null
        ? null
        : DateTime(when.year, when.month, when.day);

    final targets = <int>[
      for (var i = 0; i < avNodes.length; i++)
        if (equipmentIsTracked(avNodes[i]) &&
            (!onlyUndated || avNodes[i].installedOn == null) &&
            avNodes[i].installedOn != day)
          i,
    ];
    // Nothing to do is not an edit: it must not push an undo entry that would
    // then take back whatever the last real change was.
    if (targets.isEmpty) return 0;

    _pushAvUndo(
      day == null
          ? 'Clear the install dates on this room'
          : 'Date this room ${formatEquipmentDate(day)}',
      _flowScope,
    );
    for (final i in targets) {
      avNodes[i] = avNodes[i].copyWith(
        installedOn: day,
        clearInstalledOn: day == null,
      );
    }
    AppLogger.logInfo(
      day == null
          ? 'Install dates cleared on ${targets.length} item'
              '${targets.length == 1 ? '' : 's'} in this room.'
          : 'Install date set to ${formatEquipmentDate(day)} on '
              '${targets.length} item${targets.length == 1 ? '' : 's'} in '
              'this room.',
    );
    notifyListeners();
    return targets.length;
  }

  /// Moves a node without a full rebuild round-trip — the drag path.
  void setAvNodePosition(String nodeId, Offset pos) {
    final index = avNodes.indexWhere((n) => n.id == nodeId);
    if (index < 0) return;
    // Called once, on release — the drag itself is previewed in the view, so
    // one undo entry per move rather than one per pointer event.
    _pushAvUndo('Move ${avNodes[index].label}', _flowScope);
    avNodes[index] = avNodes[index].copyWith(pos: pos);
    notifyListeners();
  }

  /// Removes a node along with every cable touching it and its rack slot.
  /// Config-seeded nodes are remembered in [avDismissedDevices] so the next
  /// seed pass leaves them off.
  void removeAvNode(String nodeId) {
    final node = avNodeById(nodeId);
    if (node == null) return;
    _pushAvUndo('Remove ${node.label}', const {AvUndoScope.flow, AvUndoScope.racks});
    avNodes.removeWhere((n) => n.id == nodeId);
    avCables.removeWhere((c) => c.fromNodeId == nodeId || c.toNodeId == nodeId);
    final vacated = avRackSlots.remove(nodeId);
    if (vacated != null) {
      avRepackRow(vacated.rackId, vacated.face, vacated.startU);
    }
    if (node.fromConfig) avDismissedDevices.add(nodeId);
    notifyListeners();
  }

  /// Forgets which config devices were taken off the canvas by hand, so the
  /// next seed places every one of them. This is what "Place all from config"
  /// means, as opposed to the automatic first-visit seed, which respects the
  /// removals.
  void clearAvDismissedDevices() {
    if (avDismissedDevices.isEmpty) return;
    _pushAvUndo('Place all from config', _flowScope);
    avDismissedDevices.clear();
    notifyListeners();
  }

  /// Empties the signal-flow drawing so it can be built again from the config:
  /// every box, every cable, and the record of which config devices were taken
  /// off the canvas by hand.
  ///
  /// The destructive half of **Recreate from config**. A box added by hand and
  /// a cable drawn by hand go with the rest — that is what makes the result
  /// the drawing the config describes, rather than that drawing plus whatever
  /// had accumulated on top of it. The tab asks first.
  ///
  /// The RAILS are left alone. A device that comes straight back under the
  /// same config key keeps the U somebody put it on: re-reading the config is
  /// not a reason to unrack the room. What does not come back leaves a slot
  /// pointing at nothing — see [pruneAvRackSlots], which is why the snapshot
  /// covers the Racks history too.
  void clearAvFlowDrawing() {
    _pushAvUndo('Recreate from config', const {
      AvUndoScope.flow,
      AvUndoScope.racks,
    });
    avNodes.clear();
    avCables.clear();
    avDismissedDevices.clear();
    // The automatic routing pass keys off this. Cleared, it runs again over
    // the room it has just been handed.
    avRoutedFingerprint = '';
    notifyListeners();
  }

  /// Drops rack placements whose occupant is not in the room any more, and
  /// re-packs the rails they leave. Returns how many went.
  ///
  /// A slot naming something that no longer exists draws as a box with an id
  /// for a name, occupying a rail nothing is in. [recordUndo] false is for a
  /// batch that has already taken its own snapshot.
  int pruneAvRackSlots({bool recordUndo = true}) {
    final orphans = [
      for (final id in avRackSlots.keys)
        if (avNodeById(id) == null && avRackItemById(id) == null) id,
    ];
    if (orphans.isEmpty) return 0;
    if (recordUndo) _pushAvUndo('Un-rack what is gone', _racksScope);
    for (final id in orphans) {
      final vacated = avRackSlots.remove(id);
      if (vacated == null) continue;
      avRepackRow(vacated.rackId, vacated.face, vacated.startU);
    }
    notifyListeners();
    return orphans.length;
  }

  /// Draws a cable. Returns the created cable, or null when the same pair of
  /// ports is already joined (drawing it twice is always a slip).
  AvCable? addAvCable({
    required String fromNodeId,
    required String fromPortId,
    required String toNodeId,
    required String toPortId,
    required SignalType signal,
    String label = '',
    bool recordUndo = true,
  }) {
    final duplicate = avCables.any((c) =>
        (c.fromNodeId == fromNodeId &&
            c.fromPortId == fromPortId &&
            c.toNodeId == toNodeId &&
            c.toPortId == toPortId) ||
        (c.fromNodeId == toNodeId &&
            c.fromPortId == toPortId &&
            c.toNodeId == fromNodeId &&
            c.toPortId == fromPortId));
    if (duplicate) return null;

    if (recordUndo) _pushAvUndo('Draw cable', _flowScope);
    _avCableCounter++;
    final id = 'C$_avCableCounter';
    final cable = AvCable(
      id: id,
      fromNodeId: fromNodeId,
      fromPortId: fromPortId,
      toNodeId: toNodeId,
      toPortId: toPortId,
      signal: signal,
      // A run with no label is a run nobody can find again at the far end, so
      // every one is born carrying its own cable number. It is only a
      // default: the label is edited on the run's own dialog, and the cable
      // schedule and the diagram both follow whatever it says.
      label: label.isEmpty ? id : label,
    );
    avCables.add(cable);
    notifyListeners();
    return cable;
  }

  /// Replaces a cable. [recordUndo] is false on the paths that fire per
  /// pointer event — dragging a bend would otherwise fill the undo stack with
  /// twenty entries for one gesture and leave nothing useful in it.
  void updateAvCable(AvCable cable, {bool recordUndo = true}) {
    final index = avCables.indexWhere((c) => c.id == cable.id);
    if (index < 0) return;
    if (recordUndo) {
      _pushAvUndo('Edit cable ${cable.label.isEmpty ? cable.id : cable.label}', _flowScope);
    }
    avCables[index] = cable;
    notifyListeners();
  }

  void removeAvCable(String cableId) {
    _pushAvUndo('Remove cable $cableId', _flowScope);
    avCables.removeWhere((c) => c.id == cableId);
    notifyListeners();
  }

  /// How long one lead is, in feet. 0 puts it back to "not set", which the
  /// counts report in a column of its own rather than guessing.
  void setAvCableLength(String cableId, double feet) {
    final index = avCables.indexWhere((c) => c.id == cableId);
    if (index < 0) return;
    _pushAvUndo('Set cable length', _flowScope);
    avCables[index] = avCables[index].copyWith(lengthFt: feet < 0 ? 0 : feet);
    notifyListeners();
  }

  /// Sets the length on every run at once, optionally only the runs carrying
  /// [only].
  ///
  /// One undo entry for the lot: a room is cabled in one gauge of lead far
  /// more often than run by run, and thirty separate entries would bury
  /// whatever the user did before it. Returns how many runs changed.
  int setAllAvCableLengths(double feet, {SignalType? only}) {
    final length = feet < 0 ? 0.0 : feet;
    final targets = [
      for (int i = 0; i < avCables.length; i++)
        if ((only == null || avCables[i].signal == only) &&
            avCables[i].lengthFt != length)
          i,
    ];
    if (targets.isEmpty) return 0;
    _pushAvUndo('Set cable lengths', _flowScope);
    for (final i in targets) {
      avCables[i] = avCables[i].copyWith(lengthFt: length);
    }
    notifyListeners();
    return targets.length;
  }

  // --- racks ---

  RackFrame addAvRack(String name, int heightU, {String kind = ''}) {
    _pushAvUndo('Add rack $name', _racksScope);
    // Frames sit side by side; the new one goes to the right of the last.
    final rack = RackFrame(
      id: 'RACK_${avRacks.length + 1}_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      heightU: heightU,
      kind: kind,
      x: avRacks.isEmpty ? 0 : avRacks.last.x + 340,
    );
    avRacks.add(rack);
    notifyListeners();
    return rack;
  }

  void updateAvRack(RackFrame rack) {
    final index = avRacks.indexWhere((r) => r.id == rack.id);
    if (index < 0) return;
    _pushAvUndo('Edit rack ${rack.name}', _racksScope);
    avRacks[index] = rack;
    notifyListeners();
  }

  /// Removes a frame and un-racks everything that was in it.
  void removeAvRack(String rackId) {
    _pushAvUndo('Remove rack', _racksScope);
    avRacks.removeWhere((r) => r.id == rackId);
    avRackSlots.removeWhere((_, slot) => slot.rackId == rackId);
    notifyListeners();
  }

  /// Places [nodeId] in a rack, or clears its placement when [slot] is null.
  void setAvRackSlot(String nodeId, RackSlot? slot) {
    _pushAvUndo(slot == null
        ? 'Un-rack ${rackOccupantLabel(nodeId)}'
        : 'Move ${rackOccupantLabel(nodeId)}', _racksScope);
    final previous = avRackSlots[nodeId];
    if (slot == null) {
      avRackSlots.remove(nodeId);
    } else {
      avRackSlots[nodeId] = slot;
    }
    // The row it left has one fewer device on it; close the gap so two
    // survivors go back to halves rather than sitting in thirds.
    if (previous != null &&
        (slot == null ||
            slot.rackId != previous.rackId ||
            slot.face != previous.face ||
            slot.startU != previous.startU)) {
      avRepackRow(previous.rackId, previous.face, previous.startU);
    }
    notifyListeners();
  }

  /// True when [startU]..[startU]+[heightU]-1 is free in [rackId] on [face],
  /// ignoring [ignoreNodeId] (the device being moved).
  ///
  /// [half] is the side of the rail being claimed: [RackHalf.full] wants the
  /// whole width, so it clashes with anything overlapping those Us, while two
  /// half-width devices happily share a U as long as they're on opposite
  /// sides.
  bool avRackSpanIsFree({
    required String rackId,
    required RackFace face,
    required int startU,
    required int heightU,
    RackColumn slice = RackColumn.full,
    String? ignoreNodeId,
  }) {
    final rack = avRacks.firstWhere((r) => r.id == rackId,
        orElse: () => const RackFrame(id: '', name: '', heightU: 0));
    if (rack.id.isEmpty) return false;
    if (startU < 1 || startU + heightU - 1 > rack.heightU) return false;

    for (final entry in avRackSlots.entries) {
      if (entry.key == ignoreNodeId) continue;
      final slot = entry.value;
      if (slot.rackId != rackId || slot.face != face) continue;
      final otherHeight = rackOccupantHeight(entry.key).clamp(1, 60);
      final otherEnd = slot.startU + otherHeight - 1;
      final usOverlap =
          startU <= otherEnd && slot.startU <= startU + heightU - 1;
      if (usOverlap && slice.overlaps(slot.slice)) return false;
    }
    return true;
  }

  /// Everything already sitting on [startU] of [face], in slice order — the
  /// devices a newly dropped box would be sharing the rail with.
  List<String> avRackOccupantsAt({
    required String rackId,
    required RackFace face,
    required int startU,
  }) {
    final rows = avRackSlots.entries
        .where((e) =>
            e.value.rackId == rackId &&
            e.value.face == face &&
            e.value.startU == startU)
        .toList()
      ..sort((a, b) => a.value.slice.column.compareTo(b.value.slice.column));
    return [for (final e in rows) e.key];
  }

  /// Places [nodeId] on [startU], SHARING the rail with whatever is already
  /// there: the row re-splits into one more slice and the existing devices
  /// shuffle over. This is the drop path — you aim at a rack unit, not at a
  /// slice of one, which is how a Revolabs receiver, a DTP receiver and a
  /// micro PC end up listed together on one shelf.
  ///
  /// Returns false when the row already holds [kMaxRackColumns] devices, or
  /// when something spanning in from a neighboring U is in the way.
  bool avRackPlaceSharing({
    required String nodeId,
    required String rackId,
    required RackFace face,
    required int startU,
    /// False when the caller has already taken an undo snapshot — adding a new
    /// item and placing it is one action, not two.
    bool recordUndo = true,
  }) {
    final heightU = rackOccupantHeight(nodeId);
    // Where it is coming FROM, so the rail it leaves can close its gap. A drag
    // off a shared rail is the common way a row loses an occupant, and without
    // this the survivors stayed in halves (or thirds) with a hole beside them.
    final previous = avRackSlots[nodeId];

    final occupants =
        avRackOccupantsAt(rackId: rackId, face: face, startU: startU)
          ..remove(nodeId);

    // Alone on the row: take the whole width.
    if (occupants.isEmpty) {
      if (!avRackSpanIsFree(
        rackId: rackId,
        face: face,
        startU: startU,
        heightU: heightU,
        ignoreNodeId: nodeId,
      )) {
        return false;
      }
      if (recordUndo) _pushAvUndo('Rack ${rackOccupantLabel(nodeId)}', _racksScope);
      avRackSlots[nodeId] =
          RackSlot(rackId: rackId, startU: startU, face: face);
      _repackVacatedRow(previous, rackId, face, startU);
      notifyListeners();
      return true;
    }

    final columns = occupants.length + 1;
    if (columns > kMaxRackColumns) return false;

    // Re-splitting only moves devices within this row, so the one thing that
    // can still block is a taller neighbor spanning in from another U.
    final rowIds = {...occupants, nodeId};
    for (final entry in avRackSlots.entries) {
      if (rowIds.contains(entry.key)) continue;
      final slot = entry.value;
      if (slot.rackId != rackId || slot.face != face) continue;
      final otherHeight = rackOccupantHeight(entry.key).clamp(1, 60);
      final otherEnd = slot.startU + otherHeight - 1;
      if (startU <= otherEnd && slot.startU <= startU + heightU - 1) {
        return false;
      }
    }

    if (recordUndo) _pushAvUndo('Rack ${rackOccupantLabel(nodeId)}', _racksScope);
    for (int i = 0; i < occupants.length; i++) {
      final existing = avRackSlots[occupants[i]]!;
      avRackSlots[occupants[i]] =
          existing.copyWith(slice: RackColumn(column: i, columns: columns));
    }
    avRackSlots[nodeId] = RackSlot(
      rackId: rackId,
      startU: startU,
      face: face,
      slice: RackColumn(column: occupants.length, columns: columns),
    );
    _repackVacatedRow(previous, rackId, face, startU);
    notifyListeners();
    return true;
  }

  /// Closes the gap on the row an occupant just left, when it left one at all.
  /// A move within the same rail is a re-order, not a departure, so the rows
  /// are compared before the repack — otherwise the placer's own column
  /// assignment would be undone the instant it was made.
  void _repackVacatedRow(
    RackSlot? previous,
    String rackId,
    RackFace face,
    int startU,
  ) {
    if (previous == null) return;
    if (previous.rackId == rackId &&
        previous.face == face &&
        previous.startU == startU) {
      return;
    }
    avRepackRow(previous.rackId, previous.face, previous.startU);
  }

  /// Moves [nodeId] to position [target] along the rail it already shares,
  /// sliding its neighbors over rather than swapping two of them.
  void avRackReorderRow(String nodeId, int target) {
    final slot = avRackSlots[nodeId];
    if (slot == null) return;
    _pushAvUndo('Reorder ${rackOccupantLabel(nodeId)}', _racksScope);
    final order = avRackOccupantsAt(
        rackId: slot.rackId, face: slot.face, startU: slot.startU);
    order.remove(nodeId);
    order.insert(target.clamp(0, order.length), nodeId);
    for (int i = 0; i < order.length; i++) {
      final existing = avRackSlots[order[i]]!;
      avRackSlots[order[i]] =
          existing.copyWith(slice: RackColumn(column: i, columns: order.length));
    }
    notifyListeners();
  }

  /// Closes the gap after a device leaves a shared row, so two survivors go
  /// back to halves instead of leaving a hole where the third one was.
  void avRepackRow(String rackId, RackFace face, int startU) {
    final occupants =
        avRackOccupantsAt(rackId: rackId, face: face, startU: startU);
    for (int i = 0; i < occupants.length; i++) {
      final slot = avRackSlots[occupants[i]]!;
      avRackSlots[occupants[i]] = slot.copyWith(
        slice: occupants.length <= 1
            ? RackColumn.full
            : RackColumn(column: i, columns: occupants.length),
      );
    }
  }

  // --- persistence ---

  /// Sidecar the signal flow persists to ('' when the session has no working
  /// file yet — Create New that was never saved).
  ///
  /// The room's document is spread across several files now (see
  /// room_sidecar.dart); this is the one that holds the diagram and the one a
  /// room saved before the split holds ALL of, so it stays the file the app
  /// names when it has to name one.
  String get avFlowSidecarPath =>
      roomSidecarPath(currentConfigPath, RoomSidecarPart.flow);

  /// Every file the room's document is written across, by part.
  Map<RoomSidecarPart, String> get avSidecarPaths =>
      roomSidecarPaths(currentConfigPath);

  /// The name this sidecar used before it was brought in line with
  /// `<config>_control_schematic.json`. Read when the current name is absent,
  /// and retired once the diagram has been written under the new one.
  String get legacyAvFlowSidecarPath {
    if (currentConfigPath.isEmpty) return '';
    final dir = path.dirname(currentConfigPath);
    final base = path.basenameWithoutExtension(currentConfigPath);
    return path.join(dir, '${base}_avflow.json');
  }

  /// Where the AV diagram should actually be READ from: the current name when
  /// it exists, otherwise the old one. Empty when neither is there.
  String get _readableAvFlowSidecar {
    final current = avFlowSidecarPath;
    if (current.isNotEmpty && File(current).existsSync()) return current;
    final legacy = legacyAvFlowSidecarPath;
    if (legacy.isNotEmpty && File(legacy).existsSync()) return legacy;
    return '';
  }

  /// True when the session holds an AV diagram worth protecting. A cost
  /// estimate counts: tax, fees and quoted prices are work that took as long
  /// to enter as the cabling did.
  bool get hasAvFlow =>
      // A room whose only change was a config field still has something to
      // write: its log. Without this the history of a control-only room -
      // no drawing, no rack, no estimate - would be built up all session and
      // then dropped on save, which is the one thing a log must not do.
      roomHistory.isNotEmpty ||
      avNodes.isNotEmpty ||
      avCables.isNotEmpty ||
      avRacks.isNotEmpty ||
      avRackItems.isNotEmpty ||
      avLocations.isNotEmpty ||
      avScreenSwitches.isNotEmpty ||
      avFloorPlans.isNotEmpty ||
      roomMode != RoomMode.full ||
      !avCost.isEmpty;

  /// True when anything of this room's document is on disk — the flow file
  /// under either name, or any of the companion parts. A room whose only saved
  /// artifact is its cost estimate still has something worth not overwriting.
  bool get hasSavedAvFlow {
    if (_readableAvFlowSidecar.isNotEmpty) return true;
    for (final entry in avSidecarPaths.entries) {
      if (entry.key == RoomSidecarPart.flow) continue;
      if (entry.value.isNotEmpty && File(entry.value).existsSync()) return true;
    }
    return false;
  }

  /// Same prompt rule as [schematicLayoutNeedsChoice]: only ask when the
  /// session has its own diagram AND the opened config has one saved.
  bool get avFlowNeedsChoice =>
      _avFlowSyncedPath != currentConfigPath && hasAvFlow && hasSavedAvFlow;

  /// Empties the AV document without touching which config it belongs to or
  /// the undo history — what an undo needs before replaying a snapshot.
  void _clearAvFlowState() {
    roomHistory.clear();
    avNodes.clear();
    avCables.clear();
    avRacks.clear();
    avRackSlots.clear();
    avRackItems.clear();
    avLocations.clear();
    avScreenSwitches.clear();
    avFloorPlans.clear();
    avFlowBackground = const DiagramBackground();
    avDismissedDevices.clear();
    avRoutedFingerprint = '';
    avSignalColors.clear();
    avCost.clear();
    // The currency is an app setting, not a per-room one; clear() resets the
    // estimate to the built-in default, so put the chosen symbol back.
    avCost.currency = currencySymbol;
    _avNodeCounter = 0;
    _avCableCounter = 0;
    _avCostCounter = 0;
    _avRackItemCounter = 0;
    _avLocationCounter = 0;
    _avScreenSwitchCounter = 0;
    _avFloorPlanCounter = 0;
    _avCalloutCounter = 0;
    _avAnnotationCounter = 0;
    avCabling.clear();
    _avCablingBoxCounter = 0;
    _avCablingRunCounter = 0;
    // Another room's sheet is not this room's to be looking at.
    _activeFloorPlanId = '';
  }

  void _resetAvFlow() {
    _avFlowSyncedPath = currentConfigPath;
    _clearAvFlowState();
    // A different room's edits are not this room's to undo — or redo.
    _avUndoStack.clear();
    _avRedoStack.clear();
  }

  /// Keeps the in-memory AV diagram for the working config, ignoring the
  /// sidecar beside it. Nothing is written until the user saves.
  void keepAvFlowForCurrentConfig() {
    _avFlowSyncedPath = currentConfigPath;
    AppLogger.logInfo('Kept the in-memory AV flow; the saved diagram beside '
        '$currentConfigPath was not loaded.');
    notifyListeners();
  }

  /// Called when the AV Flow tab opens: reload the sidecar if the working
  /// config changed since the last visit.
  void ensureAvFlowForCurrentConfig() {
    if (_avFlowSyncedPath == currentConfigPath) return;
    loadAvFlowForCurrentConfig();
  }

  /// Replaces the in-memory AV diagram with the one saved beside the working
  /// config (blank when there is no sidecar).
  void loadAvFlowForCurrentConfig() {
    _resetAvFlow();

    /// One part file, or null when it is absent or unreadable. A broken part
    /// costs its own section and nothing else — losing the rack elevation
    /// because the cost file has a stray comma in it would be absurd.
    Map<String, dynamic>? readPart(String file, String what) {
      if (file.isEmpty || !File(file).existsSync()) return null;
      try {
        final doc = jsonDecode(File(file).readAsStringSync());
        if (doc is! Map) throw const FormatException('Root must be an object.');
        return Map<String, dynamic>.from(doc);
      } catch (e) {
        AppLogger.logError('Failed to read the $what from $file', e);
        return null;
      }
    }

    // The flow file under whichever name is on disk, so a room documented
    // before the rename opens untouched. Nothing is moved here — a read should
    // not rewrite the user's folder; the file moves on the next save.
    final flowFile = _readableAvFlowSidecar;
    final parts = <RoomSidecarPart, Map<String, dynamic>?>{
      RoomSidecarPart.flow: readPart(flowFile, 'signal flow'),
    };
    final paths = avSidecarPaths;
    for (final part in RoomSidecarPart.values) {
      if (part == RoomSidecarPart.flow) continue;
      parts[part] = readPart(paths[part] ?? '', kRoomSidecarSuffix[part]!);
    }

    if (parts.values.every((p) => p == null)) {
      // No sidecars is still a state that matches the files — an AV-only room
      // nobody has drawn yet is not an unsaved one.
      markRoomSaved();
      checkForRoomRecovery();
      notifyListeners();
      return;
    }

    // An older room's flow file holds every key and has no companions to
    // overlay it, so this hands back exactly that document.
    _readAvFlowJson(mergeRoomSidecar(parts));

    final found = [
      for (final part in RoomSidecarPart.values)
        if (parts[part] != null) kRoomSidecarSuffix[part]!,
    ];
    // The room now matches its files in full — config AND sidecars. Taken
    // here rather than at the end of the config load because that runs before
    // this does, and a baseline captured with no diagram in it would report
    // every freshly opened room as unsaved.
    markRoomSaved();

    // ...which is also the moment the recovery copy can be compared against
    // something. Anything a crash left behind is picked up here, for every way
    // a room can be opened — by hand, from the project, off a processor.
    checkForRoomRecovery();

    AppLogger.logInfo(
        'Room document loaded from ${found.join(', ')} beside '
        '$currentConfigPath (${avNodes.length} devices, '
        '${avCables.length} cables, ${avRacks.length} racks, '
        '${avRackItems.length} rack items, ${avFloorPlans.length} plans)'
        '${flowFile == legacyAvFlowSidecarPath ? ' — pre-rename file; it '
            'moves to ${path.basename(avFlowSidecarPath)} on the next '
            'Save AV Setup.' : '.'}');
    notifyListeners();
  }

  /// Reads one AV sidecar document into the live state. Shared by the file
  /// load and by [undoAvFlow], so a restored snapshot can never disagree with
  /// a loaded file about what the document contains.
  ///
  /// The caller has already emptied the state.
  void _readAvFlowJson(Map<String, dynamic> doc) {
    try {
      // The room's log. Read before the drawing rather than after, because the
      // rest of this method APPENDS to lists the caller has already emptied
      // and an exception halfway down would leave the log lost while the
      // drawing survived - which is the wrong way round for the file whose
      // whole job is to remember.
      for (final h in (doc['roomHistory'] as List? ?? [])) {
        if (h is Map) {
          roomHistory.add(ProjectEdit.fromJson(Map<String, dynamic>.from(h)));
        }
      }
      for (final n in (doc['nodes'] as List? ?? [])) {
        if (n is Map) {
          final node = AvNode.fromJson(Map<String, dynamic>.from(n));
          if (node.id.isNotEmpty) avNodes.add(node);
        }
      }
      for (final c in (doc['cables'] as List? ?? [])) {
        if (c is Map) {
          final cable = AvCable.fromJson(Map<String, dynamic>.from(c));
          if (cable.id.isNotEmpty) avCables.add(cable);
        }
      }
      for (final r in (doc['racks'] as List? ?? [])) {
        if (r is Map) {
          final rack = RackFrame.fromJson(Map<String, dynamic>.from(r));
          if (rack.id.isNotEmpty) avRacks.add(rack);
        }
      }
      for (final i in (doc['rackItems'] as List? ?? [])) {
        if (i is Map) {
          final item = RackItem.fromJson(Map<String, dynamic>.from(i));
          if (item.id.isNotEmpty) avRackItems.add(item);
        }
      }
      for (final l in (doc['locations'] as List? ?? [])) {
        if (l is Map) {
          final location =
              RoomLocation.fromJson(Map<String, dynamic>.from(l));
          if (location.id.isNotEmpty) avLocations.add(location);
        }
      }
      for (final s in (doc['screenSwitches'] as List? ?? [])) {
        if (s is Map) {
          final item = ScreenSwitch.fromJson(Map<String, dynamic>.from(s));
          if (item.id.isNotEmpty) avScreenSwitches.add(item);
        }
      }
      for (final p in (doc['floorPlans'] as List? ?? [])) {
        if (p is Map) {
          final plan = FloorPlan.fromJson(Map<String, dynamic>.from(p));
          if (plan.id.isNotEmpty) avFloorPlans.add(plan);
        }
      }
      final slots = doc['rackSlots'];
      if (slots is Map) {
        slots.forEach((nodeId, value) {
          if (value is Map) {
            avRackSlots[nodeId.toString()] =
                RackSlot.fromJson(Map<String, dynamic>.from(value));
          }
        });
      }
      final dismissed = doc['dismissedDevices'];
      if (dismissed is List) {
        avDismissedDevices.addAll(dismissed.map((e) => e.toString()));
      }
      avRoutedFingerprint = doc['routedFrom']?.toString() ?? '';
      final palette = doc['signalColors'];
      if (palette is Map) {
        palette.forEach((name, hex) {
          final value = int.tryParse(hex.toString(), radix: 16);
          if (value == null) return;
          for (final s in SignalType.values) {
            if (s.name == name.toString()) {
              avSignalColors[s] = Color(0xFF000000 | value);
            }
          }
        });
      }

      final background = doc['flowBackground'];
      if (background is Map) {
        avFlowBackground =
            DiagramBackground.fromJson(Map<String, dynamic>.from(background));
      }

      final cost = doc['cost'];
      if (cost is Map) {
        avCost.readJson(Map<String, dynamic>.from(cost));
      }
      // The sidecar records which symbol the estimate was written with, but
      // the app setting is what the shop bills in — an old room opened today
      // shows today's currency rather than reviving a symbol somebody set once.
      avCost.currency = currencySymbol;

      // Rebuild the id counters past everything that was loaded, so new
      // nodes and cables can never collide with restored ones.
      for (final n in avNodes) {
        final match = RegExp(r'^AVNODE_(\d+)$').firstMatch(n.id);
        if (match != null) {
          _avNodeCounter =
              math.max(_avNodeCounter, int.parse(match.group(1)!));
        }
      }
      for (final c in avCables) {
        final match = RegExp(r'^C(\d+)$').firstMatch(c.id);
        if (match != null) {
          _avCableCounter =
              math.max(_avCableCounter, int.parse(match.group(1)!));
        }
      }

      // Rooms drawn before cables carried their number: an unlabeled run gets
      // its cable id, which is what the schedule was printing for it anyway.
      for (var i = 0; i < avCables.length; i++) {
        if (avCables[i].label.trim().isEmpty) {
          avCables[i] = avCables[i].copyWith(label: avCables[i].id);
        }
      }
      for (final id in [
        for (final f in avCost.fees) f.id,
        for (final i in avCost.items) i.id,
        for (final i in avCost.extraEquipment) i.id,
        for (final i in avCost.extraHardware) i.id,
        for (final i in avCost.extraCables) i.id,
      ]) {
        final match = RegExp(r'_(\d+)$').firstMatch(id);
        if (match != null) {
          _avCostCounter =
              math.max(_avCostCounter, int.parse(match.group(1)!));
        }
      }
      for (final i in avRackItems) {
        final match = RegExp(r'^RACKITEM_(\d+)$').firstMatch(i.id);
        if (match != null) {
          _avRackItemCounter =
              math.max(_avRackItemCounter, int.parse(match.group(1)!));
        }
      }
      // Same rebuild for the room's places, control runs and plans, so a
      // location added after a reload can never take an id a device is
      // already pointing at.
      for (final l in avLocations) {
        final match = RegExp(r'^LOC_(\d+)$').firstMatch(l.id);
        if (match != null) {
          _avLocationCounter =
              math.max(_avLocationCounter, int.parse(match.group(1)!));
        }
      }
      for (final s in avScreenSwitches) {
        final match = RegExp(r'^SCRSW_(\d+)$').firstMatch(s.id);
        if (match != null) {
          _avScreenSwitchCounter =
              math.max(_avScreenSwitchCounter, int.parse(match.group(1)!));
        }
      }
      for (final p in avFloorPlans) {
        final match = RegExp(r'^PLAN_(\d+)$').firstMatch(p.id);
        if (match != null) {
          _avFloorPlanCounter =
              math.max(_avFloorPlanCounter, int.parse(match.group(1)!));
        }
        for (final c in p.callouts) {
          final cm = RegExp(r'^CALLOUT_(\d+)$').firstMatch(c.id);
          if (cm != null) {
            _avCalloutCounter =
                math.max(_avCalloutCounter, int.parse(cm.group(1)!));
          }
        }
        for (final a in p.annotations) {
          final am = RegExp(r'^NOTE_(\d+)$').firstMatch(a.id);
          if (am != null) {
            _avAnnotationCounter =
                math.max(_avAnnotationCounter, int.parse(am.group(1)!));
          }
        }
      }

      _migrateLegacyPlanMarkers();

      final cabling = doc['cablingSchematic'];
      if (cabling is Map) {
        avCabling.readJson(Map<String, dynamic>.from(cabling));
        for (final b in avCabling.extraBoxes) {
          final m = RegExp(r'^box:(\d+)$').firstMatch(b.id);
          if (m != null) {
            _avCablingBoxCounter =
                math.max(_avCablingBoxCounter, int.parse(m.group(1)!));
          }
        }
        for (final b in avCabling.extraBundles) {
          final m = RegExp(r'^run:(\d+)$').firstMatch(b.id);
          if (m != null) {
            _avCablingRunCounter =
                math.max(_avCablingRunCounter, int.parse(m.group(1)!));
          }
        }
      }

      // The room mode says whether a control system was ever configured. It
      // travels with the diagram because that is the document that exists for
      // an AV-only room — there may be no control config at all.
      roomMode = roomModeFromName(doc['roomMode']?.toString());
    } catch (e) {
      AppLogger.logError('Failed to read the AV flow document', e);
    }
  }

  /// Writes everything that belongs to the room but not to config.json: the
  /// AV diagram with its cost estimate, and the control schematic layout.
  /// Returns the files written.
  ///
  /// Called by every config save, so "save the project" means the project —
  /// the sidecars are not optional extras with their own buttons to forget.
  /// Each one no-ops when there is nothing to write.
  Future<List<String>> saveProjectSidecars() async {
    final written = <String>[];
    if (hasAvFlow) {
      final saved = await saveAvFlow();
      if (saved.isNotEmpty) written.add(saved);
    }
    if (hasSchematicLayout) {
      final saved = await saveSchematicLayout();
      if (saved.isNotEmpty) written.add(saved);
    }
    return written;
  }

  /// The AV diagram as it goes to disk: devices, cables, racks and the cost
  /// estimate. Public so a project export can write the same document into a
  /// room folder without a second, drifting copy of the field list.
  Map<String, dynamic> avFlowAsJson() => {
        '__readme': 'AV signal flow for the Room Config Builder: devices with '
            'their connectors, the cables between them, where each of them is '
            'in the room, rack elevations with their plates and shelves, the '
            'floor plans and their callouts, and this room\'s cost estimate '
            '(tax, fees, labor and quoted prices).',
        'nodes': avNodes.map((n) => n.toJson()).toList(),
        'cables': avCables.map((c) => c.toJson()).toList(),
        'racks': avRacks.map((r) => r.toJson()).toList(),
        'rackItems': avRackItems.map((i) => i.toJson()).toList(),
        'rackSlots': avRackSlots.map((id, s) => MapEntry(id, s.toJson())),
        'locations': avLocations.map((l) => l.toJson()).toList(),
        'screenSwitches': avScreenSwitches.map((s) => s.toJson()).toList(),
        if (!avCabling.isEmpty) 'cablingSchematic': avCabling.toJson(),
        if (avFlowBackground.hasImage)
          'flowBackground': avFlowBackground.toJson(),
        'floorPlans': avFloorPlans.map((p) => p.toJson()).toList(),
        'dismissedDevices': avDismissedDevices.toList(),
        if (avRoutedFingerprint.isNotEmpty)
          'routedFrom': avRoutedFingerprint,
        'roomMode': roomMode.name,
        'signalColors': {
          for (final e in avSignalColors.entries)
            e.key.name: (e.value.toARGB32() & 0xFFFFFF)
                .toRadixString(16)
                .padLeft(6, '0'),
        },
        'cost': avCost.toJson(),
        if (roomHistory.isNotEmpty)
          'roomHistory': [for (final h in roomHistory) h.toJson()],
      };

  /// Writes the AV sidecar. Returns the saved path, or '' when there is no
  /// working config file to sit next to (or the write failed).
  Future<String> saveAvFlow() async {
    final sidecar = avFlowSidecarPath;
    if (sidecar.isEmpty) return '';
    try {
      const encoder = JsonEncoder.withIndent('  ');

      // One file per part. The flow file is written LAST: it is the one the
      // loader always reads and the one an older room holds everything in, so
      // until it has been rewritten without them, its stale copies of the
      // companions' keys are still the truth. Writing it first would leave a
      // window where a crash had split the document but left the flow file
      // claiming to own all of it.
      final parts = splitRoomSidecar(avFlowAsJson());
      final paths = avSidecarPaths;
      for (final part in RoomSidecarPart.values) {
        if (part == RoomSidecarPart.flow) continue;
        final file = paths[part];
        if (file == null || file.isEmpty) continue;
        await File(file).writeAsString(encoder.convert(parts[part]));
      }
      await File(sidecar).writeAsString(
        encoder.convert(parts[RoomSidecarPart.flow]),
      );

      // The write succeeded, so the pre-rename file is now a stale duplicate
      // that would quietly diverge. Retire it — but only ever AFTER the new
      // file is safely on disk.
      final legacy = legacyAvFlowSidecarPath;
      if (legacy.isNotEmpty && legacy != sidecar) {
        final old = File(legacy);
        if (old.existsSync()) {
          try {
            await old.delete();
            AppLogger.logInfo(
                'AV flow moved to ${path.basename(sidecar)}; removed the old '
                '${path.basename(legacy)}.');
          } catch (e) {
            // Not fatal: the diagram is saved either way, and the loader
            // prefers the new name from here on.
            AppLogger.logError(
                'Saved the AV flow, but could not remove the old $legacy', e);
          }
        }
      }

      _avFlowSyncedPath = currentConfigPath;
      return sidecar;
    } catch (e, stack) {
      AppLogger.logError('Failed to save AV flow to $sidecar', e, stack);
      return '';
    }
  }

  List<String> systemLogs = []; // NEW: Store user-facing session logs
  
  // Cache for parsed python module commands to prevent repetitive disk I/O
  final Map<String, List<String>> _moduleCommandsCache = {};
  // Cache for parsed python module inputs (previously re-read from disk on every rebuild)
  final Map<String, List<String>> _moduleInputsCache = {};
  // Cache for per-command state lists ("<module path>::<command>"), used by
  // the schema-driven "module_states" field type.
  final Map<String, List<String>> _moduleStatesCache = {};
  // All python modules discovered under modulesPath (dot notation), for the
  // module selection dropdown/autocomplete on device tabs.
  List<String> availableModules = [];

  /// [availableModules] in the form the config stores — `modules.device.<stem>`.
  /// The device tab's picker and autocomplete offer these, so what is selected
  /// is exactly what is written and the field never shows a bare stem the
  /// processor could not import.
  List<String> get availableModuleImports =>
      availableModules.map(normalizeModuleName).toList();

  // --- MODEL REGISTRY -------------------------------------------------
  // Every model name found across the module files, mapped to the module
  // that should be used for it. Sources, in order of authority:
  //   1. a module-level DEVICE_INFO = { "models": [...] } dict (explicit —
  //      marks that file as the DEFAULT module for those models)
  //   2. the keys of the driver's own self.Models = {...} dict (fallback,
  //      so the dropdown works even before DEVICE_INFO is added)
  final Map<String, ModelEntry> modelRegistry = {};
  // Per-module property defaults: DEVICE_INFO["connection"] merged with
  // DEVICE_INFO["defaults"] (two keys in the file purely for readability).
  // Keys are config.json device properties (protocol, net_port, com_type,
  // keep_alive_command, input, ...) applied when a model is picked.
  final Map<String, Map<String, dynamic>> moduleDefaults = {};

  /// Per-module, per-connection defaults: DEVICE_INFO's "network", "serial"
  /// and "serialoverethernet" blocks (and "http"), keyed module stem ->
  /// normalized com_type -> properties.
  ///
  /// A driver usually reaches its box more than one way — the same projector
  /// on RS-232 in one room and on the network in the next — and the port,
  /// protocol and baud that go with each are facts about the DEVICE, not about
  /// the room. One flat "connection" block can only spell out whichever way
  /// the author happened to write down, so changing com_type in the editor
  /// left the wrong port behind and somebody found out on site. These blocks
  /// are what the editor loads when the connection style changes, and what a
  /// model pick merges over the flat defaults for the connection it lands on.
  ///
  /// Keyed the same way as [moduleDefaults], and empty for every driver that
  /// has not declared any.
  final Map<String, Map<String, Map<String, dynamic>>> moduleComTypeDefaults =
      {};

  /// Per-module DEVICE_INFO "omit" lists: config-key patterns the model does
  /// NOT use, so a family default that supplies them gets undone. Keyed by
  /// module stem, same as [moduleDefaults].
  final Map<String, List<String>> moduleOmits = {};

  /// Every model name a module covers, keyed by module stem. One driver often
  /// serves a whole product line (the 82 4K and the 84 4K share a file), while
  /// its DEVICE_INFO "defaults" can only spell out ONE of them in the device
  /// name. This is what lets [_modelSubstitute] rewrite that name to whichever
  /// model was actually picked.
  final Map<String, List<String>> moduleModels = {};

  /// Sorted model names for the device-tab Model dropdown (every model).
  List<String> get availableModels => modelRegistry.keys.toList()..sort();

  /// The registry entry for [model], matched the way a converted room needs.
  ///
  /// [modelRegistry] is keyed by the string the DRIVER spells — 'VIA GO',
  /// 'TR311HW' — and a legacy file spells the same box however whoever typed
  /// it felt at the time: 'Via Go', 'tr311hw'. An exact lookup therefore says
  /// "no driver claims this model" about a device whose driver is sitting
  /// right there, and everything downstream of the lookup then has nothing to
  /// say: no module, no connection defaults, no review.
  ///
  /// That is what kept the VIA GO on the wireless family's SSH when its own
  /// driver says TCP on 9982 — the module resolution matched 'Via Go'
  /// case-insensitively and filled the module in, and the defaults review
  /// looked the same string up exactly, missed, and skipped the device. One
  /// lookup for both, so the two can never disagree about what a model is
  /// again.
  ///
  /// Case and surrounding space only. Spelling the spaces differently
  /// ('DMP128 Plus' for 'DMP 128 Plus') is still a miss: that is a different
  /// string rather than the same one shouted, and guessing across it is how
  /// the wrong driver gets picked.
  ModelEntry? modelEntryFor(String model) {
    final name = model.trim();
    if (name.isEmpty) return null;
    final exact = modelRegistry[name];
    if (exact != null) return exact;
    final wanted = name.toLowerCase();
    for (final entry in modelRegistry.values) {
      if (entry.model.toLowerCase().trim() == wanted) return entry;
    }
    return null;
  }

  /// The modules-folder-relative stem of a config `module` value — the inverse
  /// of [normalizeModuleName]. The config stores the import path the processor
  /// needs ('modules.device.avr_TR311'), but the file sits at
  /// `<modules path>/avr_TR311.py`, so that prefix must come off before the
  /// remaining dots become folder separators. A bare stem, a '.py' suffix, or a
  /// sub-foldered 'vendor.model' value all resolve the same way — which is what
  /// lets one preload (keyed by the stem) serve both spellings instead of the
  /// dropdowns coming up empty until the module is picked again by hand.
  static String moduleStem(String raw) => raw
      .trim()
      .replaceAll(RegExp(r'\.py$', caseSensitive: false), '')
      .replaceAll(RegExp(r'[\\/]'), '.')
      .replaceFirst(RegExp(r'^modules\.'), '')
      .replaceFirst(RegExp(r'^devices?\.'), '');

  /// Absolute path of the .py file backing a config `module` value ('' when the
  /// value is blank). See [moduleStem] for how the import prefix is handled.
  String modulePyPath(String moduleValue) {
    final stem = moduleStem(moduleValue);
    if (stem.isEmpty) return '';
    return path.join(
        effectiveModulesPath, '${stem.replaceAll('.', path.separator)}.py');
  }

  /// The module's DEVICE_INFO connection/defaults, accepting either the dotted
  /// config spelling or the bare stem [moduleDefaults] is keyed by.
  Map<String, dynamic>? moduleDefaultsFor(String moduleValue) =>
      moduleDefaults[moduleStem(moduleValue)];

  /// The module's own defaults for one connection style, or null when the
  /// driver has not published a block for it. [comType] is the config value
  /// ('SerialOverEthernet'), spelled however the schema spells it.
  Map<String, dynamic>? comTypeDefaultsFor(String moduleValue, String comType) =>
      moduleComTypeDefaults[moduleStem(moduleValue)]
          ?[normalizeComTypeName(comType)];

  /// The connection styles [moduleValue] publishes a block for, in the schema's
  /// spelling and the order the com_type dropdown lists them.
  ///
  /// What the driver-defaults review offers to compare against: a device on a
  /// COM port should be able to ask "what does my driver say about SERIAL",
  /// not only about whichever connection the module happens to name first.
  List<String> comTypeStylesFor(String moduleValue) {
    final blocks = moduleComTypeDefaults[moduleStem(moduleValue)];
    if (blocks == null) return const [];
    return [
      for (final style in kComTypeStyleLabels.keys)
        if (blocks.containsKey(style)) kComTypeStyleLabels[style]!,
    ];
  }

  /// The comparison spelling of a com_type: lower case, letters and digits
  /// only, so 'SerialOverEthernet', 'serial_over_ethernet' and
  /// 'Serial Over Ethernet' are one connection style and not three.
  static String normalizeComTypeName(String raw) =>
      raw.trim().toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  /// [moduleDefaults] for [moduleKey] with the per-connection block laid over
  /// it — the defaults a model pick should actually write.
  ///
  /// Which block that is comes from the defaults themselves when they name a
  /// com_type, and from the device otherwise: a driver whose flat defaults say
  /// "Network" gets its network block, and one that says nothing about the
  /// connection leaves the device on the one it is already on.
  ///
  /// [comType] overrides both. Picking a model is the driver telling you how
  /// the box is reached, so there the module's own answer should win — but
  /// REVIEWING a device that is already on a COM port is a different question,
  /// and answering it with the network block is how a serial device came to be
  /// offered a net_port. The review passes the connection it is asking about.
  Map<String, dynamic> _mergedModuleDefaults(
      String moduleKey, String deviceKey, {String? comType}) {
    final base =
        Map<String, dynamic>.from(moduleDefaults[moduleKey] ?? const {});
    final dev = roomConfig[deviceKey];
    if (comType != null && comType.isNotEmpty) {
      final wanted =
          moduleComTypeDefaults[moduleKey]?[normalizeComTypeName(comType)];
      if (wanted != null) {
        // The connection asked about, and the com_type that goes with it: a
        // review that proposes a baud rate has to propose the Serial that
        // makes the baud rate mean something.
        base.addAll(wanted);
        base['com_type'] = comType;
        return base;
      }
    }
    final resolved = (base['com_type'] ??
            (dev is Map ? dev['com_type'] : null) ??
            '')
        .toString();
    if (resolved.isEmpty) return base;
    return _layerComTypeBlock(base, moduleKey, resolved);
  }

  Map<String, dynamic> _layerComTypeBlock(
      Map<String, dynamic> base, String moduleKey, String comType) {
    final block =
        moduleComTypeDefaults[moduleKey]?[normalizeComTypeName(comType)];
    // The connection block wins: it is the more specific statement, and the
    // flat block's port is whichever one the author wrote down first.
    if (block != null) base.addAll(block);
    return base;
  }

  /// Config-key patterns a module's DEVICE_INFO "omit" list says the model does
  /// not use, keyed the same way as [moduleDefaults]. Empty for most modules.
  List<String> moduleOmitsFor(String moduleValue) =>
      moduleOmits[moduleStem(moduleValue)] ?? const [];

  /// True when [key] matches any pattern in [patterns]. Patterns are plain key
  /// names or globs with '*' ("group_*"); matching is case-insensitive so a
  /// legacy block's GROUP_PROG_GAIN is caught alongside group_prog_gain.
  @visibleForTesting
  static bool keyMatchesOmitPattern(String key, List<String> patterns) {
    for (final pattern in patterns) {
      final regex = RegExp(
          '^${pattern.split('*').map(RegExp.escape).join('.*')}\$',
          caseSensitive: false);
      if (regex.hasMatch(key)) return true;
    }
    return false;
  }

  /// Model names offered on [deviceKey]'s tab: only models whose module's
  /// DEVICE_INFO declares a matching "device_type". Untyped models (no
  /// DEVICE_INFO device_type, e.g. the self.Models fallbacks) are left out —
  /// they surface only through the picker's "Show all device types" checkbox.
  List<String> availableModelsFor(String deviceKey) {
    return modelRegistry.values
        .where((e) => modelMatchesDevice(e, deviceKey))
        .map((e) => e.model)
        .toList()
      ..sort();
  }

  /// True when [entry]'s device_type list matches [deviceKey]'s family.
  /// Token-based against the family's section prefix, count key, and label
  /// words, so "projector", "display", or "Projectors" all hit the
  /// PROJECTORDEVICE_ family. A model with NO declared device_type is filtered
  /// OUT of a known family (checkbox-only); a deviceKey outside every known
  /// family isn't filtered at all (nothing to match against).
  bool modelMatchesDevice(ModelEntry entry, String deviceKey) {
    final spec = uiSchema.deviceTypeForSection(deviceKey);
    if (spec == null) return true; // unknown family: no device_type to filter on
    if (entry.deviceTypes.isEmpty) return false; // untyped: checkbox-only
    final Set<String> familyTokens = {
      normalizeDeviceTypeToken(spec.prefix),
      normalizeDeviceTypeToken(spec.countKey.replaceFirst('dev_', '')),
      for (final w in spec.label.split(RegExp(r'[^A-Za-z0-9]+')))
        if (w.isNotEmpty) normalizeDeviceTypeToken(w),
    }..remove('');
    return entry.deviceTypes
        .any((t) => familyTokens.contains(normalizeDeviceTypeToken(t)));
  }

  /// Lowercases, strips non-alphanumerics, and drops 'device' / plural-s
  /// suffixes: 'PROJECTORDEVICE_', 'Projectors', 'projector' all become
  /// 'projector'.
  static String normalizeDeviceTypeToken(String s) {
    var t = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (t.endsWith('device')) t = t.substring(0, t.length - 6);
    if (t.endsWith('s') && t.length > 1) t = t.substring(0, t.length - 1);
    return t;
  }

  /// Attempts to find commonly named inputs inside the Python module for the autocomplete field
  Future<List<String>> getInputsForModule(String moduleFileName) async {
    final fullPath = modulePyPath(moduleFileName);

    // Serve from cache when the module was already parsed (startup preload or prior visit)
    if (_moduleInputsCache.containsKey(fullPath)) {
      return _moduleInputsCache[fullPath]!;
    }

    try {
      final file = File(fullPath);
      // If no file exists, return some default Extron input strings
      if (!await file.exists()) return ['HDMI 1', 'HDMI 2', 'VGA', 'HDBaseT', 'DisplayPort']; 
      
      final content = await file.readAsString();
      
      // Look for common Extron string literals that represent inputs
      final RegExp inputRegex = RegExp(r"['""](HDMIs*d*|HDBaseT|VGA|DisplayPort|DVI|SDI|Composite|Component|Videos*d*|RGB|Type-C|USB-C)['""]", caseSensitive: false);
      
      final Set<String> inputs = {};
      for (final match in inputRegex.allMatches(content)) {
        if (match.group(1) != null) {
          inputs.add(match.group(1)!);
        }
      }
      
      final result = inputs.isEmpty
          ? ['HDMI 1', 'HDMI 2', 'VGA', 'HDBaseT', 'DisplayPort']
          : (inputs.toList()..sort());
      _moduleInputsCache[fullPath] = result;
      return result;
    } catch (e) {
      return ['HDMI 1', 'HDMI 2', 'VGA', 'HDBaseT'];
    }
  }

  /// Scans the entire modules directory at startup (or when the path changes)
  /// and parses every .py file into the command/input caches up front.
  /// Fault-tolerant: one unreadable file or folder no longer aborts the scan.
  Future<void> preloadAllModules() async {
    // Resolve once: explicit setting, else "<root>/devices" (see getters).
    final String mPath = effectiveModulesPath;
    final List<String> discovered = [];
    // Rebuilt from scratch on every scan so renamed/removed files drop out.
    modelRegistry.clear();
    moduleDefaults.clear();
    moduleComTypeDefaults.clear();
    moduleOmits.clear();
    moduleModels.clear();
    try {
      final dir = Directory(mPath);
      if (!await dir.exists()) {
        if (modulesPath.isEmpty) {
          // Default folder simply not created yet — not an error.
          AppLogger.logInfo(
              "Default modules folder not found (looked in $mPath). "
              "Create a 'devices' sub-folder in the root folder or set the Modules Path in App Config.");
        } else {
          AppLogger.logError("Modules path does not exist: $mPath");
        }
        return;
      }

      // Collect entries first, tolerating unreadable folders/links mid-scan
      final List<FileSystemEntity> entities = [];
      await for (final entity in dir
          .list(recursive: true, followLinks: false)
          .handleError((err) => AppLogger.logError("Skipped unreadable entry while scanning modules", err))) {
        entities.add(entity);
      }

      for (final entity in entities) {
        try {
          if (entity is! File) continue;
          final p = entity.path;
          if (!p.toLowerCase().endsWith('.py')) continue;
          if (p.contains('__pycache__')) continue; // Compiled/cache dirs are never modules

          // Convert the file path back into the dot-notation used by the config
          String rel = path.relative(p, from: mPath);
          String moduleName = rel
              .replaceAll(RegExp(r'\.py$', caseSensitive: false), '')
              .replaceAll(RegExp(r'[\\/]'), '.');
          discovered.add(moduleName);
          await getCommandsForModule(moduleName);
          await getInputsForModule(moduleName);
          await _registerModuleModels(moduleName);
        } catch (e) {
          // Skip this one file, keep parsing the rest
          AppLogger.logError("Skipped unparseable module ${entity.path}", e);
        }
      }
      AppLogger.logInfo("Preloaded ${discovered.length} python module dictionaries from $mPath");
    } catch (e, stack) {
      AppLogger.logError("Failed to preload python module dictionaries", e, stack);
    } finally {
      // Publish whatever was found, even after a partial failure, so the
      // module dropdown and keep-alive lists work with the successful portion.
      availableModules = discovered..sort();
      notifyListeners();
    }
  }

  /// Warms the parser caches for every module referenced by the active config.
  /// Called after any config is loaded so device tabs open instantly.
  /// Works out where every value in the converted config came from, and what
  /// the conversion changed, by diffing the working config against the file as
  /// it was parsed.
  ///
  /// A key that existed in the corresponding ORIGINAL section with the SAME
  /// value is [ValueOrigin.legacy]; one whose value the conversion rewrote is
  /// [ValueOrigin.changed] (a rename alone is not a rewrite — the value is
  /// what is being colored); a key the conversion introduced is
  /// [ValueOrigin.written]. Sections are lined up through [sectionRenames],
  /// and keys through the same lowercase/no-underscore comparison
  /// auto_case_normalization uses, so COMTYPE and com_type are recognized as
  /// the same property.
  ///
  /// Root-level scalars (`startup_watchdog_stage`, which the processor writes
  /// into the file itself) are diffed too, under an empty field key. They used
  /// to be skipped along with every other non-Map, which drew them orange
  /// whatever had happened to them and kept them out of the change list
  /// entirely.
  @visibleForTesting
  void computeConversionProvenance(
    Map<String, String> sectionRenames,
    List<ConversionConflict> conflicts,
  ) {
    valueOrigins.clear();
    conversionChanges.clear();

    // Converted section name -> its name in the loaded file
    final Map<String, String> originalSectionOf = {
      for (final entry in sectionRenames.entries) entry.value: entry.key,
    };

    String norm(String s) => s.toLowerCase().replaceAll('_', '');

    /// The original block a converted section came from, keyed by normalized
    /// property name, plus the original spelling of each key.
    (Map<String, dynamic>, Map<String, String>) originalBlock(String section) {
      final name = originalSectionOf[section] ?? section;
      final block = _originalLoadedConfig[name];
      if (block is! Map) return (const {}, const {});
      final byNorm = <String, dynamic>{};
      final spelling = <String, String>{};
      block.forEach((k, v) {
        byNorm[norm(k.toString())] = v;
        spelling[norm(k.toString())] = k.toString();
      });
      return (byNorm, spelling);
    }

    /// Records one surviving value: its origin, and the rejectable change when
    /// the conversion added or rewrote it. [key] is '' for a root scalar.
    void record(String sectionKey, String key, dynamic value,
        {required bool wasInFile, dynamic before}) {
      final id = '$sectionKey.$key';
      if (!wasInFile) {
        valueOrigins[id] = ValueOrigin.written;
        conversionChanges.add(ConversionChange(
          section: sectionKey,
          key: key,
          kind: ConversionKind.added,
          after: value,
        ));
        return;
      }
      if (jsonEncode(before) == jsonEncode(value)) {
        valueOrigins[id] = ValueOrigin.legacy;
        return;
      }
      // Same key, new value: the conversion wrote what is on screen, so it
      // gets its own color as well as a rejectable change.
      valueOrigins[id] = ValueOrigin.changed;
      conversionChanges.add(ConversionChange(
        section: sectionKey,
        key: key,
        kind: ConversionKind.changed,
        before: before,
        after: value,
      ));
    }

    // --- Values that survived into the working config ----------------------
    roomConfig.forEach((sectionKey, block) {
      if (block is! Map) {
        // A scalar at the root of the file rather than a settings block.
        final originalName = originalSectionOf[sectionKey] ?? sectionKey;
        final bool wasInFile =
            _originalLoadedConfig.containsKey(originalName) &&
                _originalLoadedConfig[originalName] is! Map;
        record(sectionKey, '', block,
            wasInFile: wasInFile,
            before: wasInFile ? _originalLoadedConfig[originalName] : null);
        return;
      }
      final (originalByNorm, _) = originalBlock(sectionKey);
      block.forEach((rawKey, value) {
        final key = rawKey.toString();
        final n = norm(key);
        record(sectionKey, key, value,
            wasInFile: originalByNorm.containsKey(n),
            before: originalByNorm[n]);
      });
    });

    // --- Values the conversion dropped -------------------------------------
    // Indexed by conflict id so a removed property that was ALSO a conflict
    // (an IP on a serial device) carries its reason into the preview.
    final Map<String, ConversionConflict> conflictById = {
      for (final c in conflicts) '${c.section}.${c.key}': c,
    };
    for (final c in conflicts) {
      conversionChanges.add(ConversionChange(
        section: c.section,
        key: c.key,
        kind: ConversionKind.removed,
        before: c.value,
        conflictReason: c.reason,
      ));
    }

    _originalLoadedConfig.forEach((originalSection, block) {
      // Where did this section end up? (unchanged name, or its rename)
      final String section = sectionRenames[originalSection] ?? originalSection;
      if (block is! Map) {
        // A root scalar the conversion dropped (the 'ROOM' removal rule and
        // the like) — reported like any other removal instead of vanishing.
        if (!roomConfig.containsKey(section)) {
          conversionChanges.add(ConversionChange(
            section: section,
            key: '',
            kind: ConversionKind.removed,
            before: block,
          ));
        }
        return;
      }
      final current = roomConfig[section];
      final Set<String> survivingNorms = current is Map
          ? current.keys.map((k) => norm(k.toString())).toSet()
          : <String>{};
      block.forEach((rawKey, value) {
        final key = rawKey.toString();
        if (survivingNorms.contains(norm(key))) return;
        // Conflicts were already added above, with their reason attached
        if (conflictById.containsKey('$section.$key')) return;
        conversionChanges.add(ConversionChange(
          section: section,
          key: key,
          kind: ConversionKind.removed,
          before: value,
        ));
      });
    });

    conversionChanges.sort((a, b) {
      final s = a.section.compareTo(b.section);
      return s != 0 ? s : a.key.compareTo(b.key);
    });
  }

  /// Normalizes a config `module` value into the dotted form the processor
  /// imports — `modules.device.<file stem>`. Accepts a bare stem, a file path,
  /// a name with the .py still on it, or a half-qualified 'device.foo', and
  /// leaves an already-correct value untouched.
  static String normalizeModuleName(String raw) {
    var name = raw.trim();
    if (name.isEmpty) return name;
    name = name
        .replaceAll(RegExp(r'\.py$', caseSensitive: false), '')
        .replaceAll(RegExp(r'[\\/]'), '.');
    if (name.startsWith('modules.device.')) return name;
    // Strip a leading 'modules.' and/or 'device.'/'devices.' so a partially
    // qualified value doesn't come out doubled.
    name = name
        .replaceFirst(RegExp(r'^modules\.'), '')
        .replaceFirst(RegExp(r'^devices?\.'), '');
    return name.isEmpty ? '' : 'modules.device.$name';
  }

  /// Fills a device's `module` from its `model` using the parsed module
  /// registry when the converted config didn't carry one, and rewrites every
  /// module value into the `modules.device.` form. A model no module claims is
  /// flagged rather than guessed at. Each change lands in systemLogs.
  Future<void> _resolveDeviceModules() async {
    // The registry is warmed in the background at startup — make sure it has
    // actually landed before concluding that a model is unknown.
    if (modelRegistry.isEmpty) await preloadAllModules();

    roomConfig.forEach((sectionKey, block) {
      if (block is! Map) return;
      if (uiSchema.deviceTypeForSection(sectionKey) == null) return;
      final Map<String, dynamic> section = block as Map<String, dynamic>;

      final String module = section['module']?.toString().trim() ?? '';

      if (module.isEmpty) {
        final String model = section['model']?.toString().trim() ?? '';
        if (model.isEmpty) return; // nothing to look the module up by
        final ModelEntry? match = modelEntryFor(model);
        if (match == null) {
          systemLogs.add(
              "FLAGGED: '$sectionKey.module' is empty and no python module "
              "claims model '$model' - set it by hand.");
          return;
        }
        final String resolved = normalizeModuleName(match.module);
        section['module'] = resolved;
        systemLogs.add(
            "MODULE: '$sectionKey.module' set to '$resolved' from model '$model'.");
        return;
      }

      final String normalized = normalizeModuleName(module);
      if (normalized != module) {
        section['module'] = normalized;
        systemLogs.add(
            "MODULE: '$sectionKey.module' rewritten '$module' -> '$normalized'.");
      }
    });
  }

  void _preloadModulesFromConfig() {
    roomConfig.forEach((key, value) {
      if (value is Map && value['module'] is String && (value['module'] as String).isNotEmpty) {
        // Fire-and-forget: results land in the caches used by the FutureBuilders
        getCommandsForModule(value['module']);
        getInputsForModule(value['module']);
      }
    });
  }

  Future<bool> uploadConfigToProcessor({
    required String ipAddress,
    required String password,
    required Function(String) onStatusUpdate,
    String? extraFilePath, // Optional additional file (e.g. Whereused.csv)
  }) async {
    pendingRawEditorCommit?.call(); // Raw-editor typing goes up with it
    if (roomConfig.isEmpty) {
      onStatusUpdate("Error: No configuration loaded to upload.");
      return false;
    }

    // Validate the optional attachment up front so we don't push a config
    // and THEN discover the second file is missing.
    if (extraFilePath != null && extraFilePath.isNotEmpty) {
      if (!await File(extraFilePath).exists()) {
        onStatusUpdate("Error: Additional file not found: $extraFilePath");
        return false;
      }
    }

    try {
      onStatusUpdate("System: Preparing configuration data...");

      // 1. Clean out unused devices, sort keys, and format as a clean JSON string
      Map<String, dynamic> exportData = _pruneConfig(roomConfig);
      final encoder = const JsonEncoder.withIndent('    ');
      final jsonString = encoder.convert(_sortJson(exportData));

      // 2. Create a temporary directory and file
      // SftpLogger expects a physical file path, so we write the JSON string to a temp file
      final tempDir = await Directory.systemTemp.createTemp('deployment_app_');
      final tempFile = File(path.join(tempDir.path, 'config.json'));
      await tempFile.writeAsString(jsonString);

      // 3. Instantiate your existing SftpLogger and trigger the upload
      final sftpClient = SftpLogger();
      bool success = await sftpClient.uploadFileToProcessor(
        ipAddress: ipAddress,
        password: password,
        inputPath: tempFile.path,
        // Target path / credentials from App Config > Processor Connection
        remoteFilename: sftpRemoteConfigPath,
        username: sftpUsername,
        port: effectiveSftpPort,
        onStatusUpdate: onStatusUpdate,
      );

      if (success) {
        AppLogger.logInfo("Successfully uploaded config.json to $ipAddress");
      } else {
        AppLogger.logError("Failed SFTP upload of config.json to $ipAddress");
      }

      // 3b. Upload the optional additional file (e.g. Whereused.csv) to the
      // processor root, keeping its own file name. Only attempted after a
      // successful config upload; overall success requires BOTH.
      if (success && extraFilePath != null && extraFilePath.isNotEmpty) {
        final extraName = path.basename(extraFilePath);
        onStatusUpdate("System: Uploading additional file $extraName...");
        final extraOk = await sftpClient.uploadFileToProcessor(
          ipAddress: ipAddress,
          password: password,
          inputPath: extraFilePath,
          remoteFilename: '/$extraName',
          username: sftpUsername,
          port: effectiveSftpPort,
          onStatusUpdate: onStatusUpdate,
        );
        if (extraOk) {
          AppLogger.logInfo("Successfully uploaded $extraName to $ipAddress");
          onStatusUpdate("System: Upload complete. Wrote /config.json and /$extraName");
        } else {
          AppLogger.logError("Failed SFTP upload of $extraName to $ipAddress");
          onStatusUpdate(
              "System Error: config.json uploaded, but $extraName FAILED. Retry the additional file.");
          success = false;
        }
      }

      // 4. Clean up the temporary file immediately so we don't clutter the OS
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      
      // Also delete the temp directory itself
      if (await tempDir.exists()) {
        await tempDir.delete();
      }

      return success;
      
    } catch (e, stack) {
      AppLogger.logError("Failed to upload config directly to processor", e, stack);
      onStatusUpdate("System Error: Failed to prepare upload. $e");
      return false;
    }
  }

  // --- Constructor triggers auto-load on startup ---
  // Tests pass autoLoadSettings: false — it disables BOTH the load and every
  // later save. Widget tests drive real UI (theme toggles, updateSetting)
  // whose saves would hit the developer's real app_config.json; worse, a
  // write started inside a test's fake-async zone can be killed mid-flight
  // at teardown, leaving a truncated 0-byte file.
  /// Where the processor password lives — the OS keystore in the app, an
  /// in-memory stand-in under `flutter test` (which has no platform plugin).
  late final SecretStore _secrets;

  AppStateProvider({bool autoLoadSettings = true, SecretStore? secretStore}) {
    _persistenceEnabled = autoLoadSettings;
    // A test provider gets a memory store unless it asks for a real one, so no
    // test ever depends on a keystore being present.
    _secrets = secretStore ??
        (autoLoadSettings ? OsSecretStore() : InMemorySecretStore());
    if (autoLoadSettings) _loadSavedSettings();
  }

  /// False on test-constructed providers: never touch app_config.json.
  bool _persistenceEnabled = true;

  /// Loads saved settings from app_config.json in the root folder. The file
  /// is (re)written with the resolved values on every startup, so it exists
  /// with working defaults from the very first launch — the app starts even
  /// when no folder or location has ever been selected. Settings saved by
  /// older versions in the OS store are imported once.
  Future<void> _loadSavedSettings() async {
    try {
      settingsFilePath = _resolveSettingsFilePath();
      // Carry an older build's app-folder settings over the first time the
      // per-user location is used, so nothing is re-entered after an update.
      _migrateLegacySettingsFile(settingsFilePath);
      Map<String, dynamic> saved = {};
      final file = File(settingsFilePath);
      if (await file.exists()) {
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map<String, dynamic>) saved = decoded;
        } catch (e, stack) {
          // Broken JSON (hand-edit typo): keep a copy for inspection and
          // continue on defaults; the rewrite below recreates a valid file.
          AppLogger.logError(
              'app_config.json is not valid JSON - starting with defaults '
              '(original kept as app_config.json.invalid)', e, stack);
          try {
            await file.copy('$settingsFilePath.invalid');
          } catch (_) {}
        }
      } else {
        // No app_config.json yet: import settings from older versions
        saved = await _migrateFromSharedPreferences();
      }

      String str(String key, String fallback) {
        final v = saved[key]?.toString() ?? '';
        return v.isEmpty ? fallback : v;
      }

      modulesPath = str('modulesPath', '');
      processorsFilePath = str('processorsFilePath', '');
      rootFolderPath = str('rootFolderPath', '');
      buildingsFilePath = str('buildingsFilePath', '');
      templateFilePath = str('templateFilePath', '');
      uiSchemaPath = str('uiSchemaPath', '');
      keyMapPath = str('keyMapPath', '');
      avDevicesFilePath = str('avDevicesFilePath', '');
      flowRulesFilePath = str('flowRulesFilePath', '');
      documentationPath = str('documentationPath', '');
      sftpUsername = str('sftpUsername', 'admin');
      sftpPort = str('sftpPort', '22022');
      sftpRemoteConfigPath = str('sftpRemoteConfigPath', '/config.json');
      useDefaultProcessorPassword =
          saved['useDefaultProcessorPassword'] is bool
              ? saved['useDefaultProcessorPassword']
              : false;
      // From the OS keystore, not this file — and migrated out of it if an
      // older build left a plain-text copy behind.
      await _loadProcessorPassword(saved);
      isDarkMode = saved['isDarkMode'] is bool ? saved['isDarkMode'] : true;
      themeStyle = str('themeStyle', 'classic');
      classicColor = str('classicColor', '2196F3');
      aurisColor = str('aurisColor', 'F0A500');
      classicSecondary = str('classicSecondary', '');
      textScale = double.tryParse(str('textScale', '')) ?? 1.0;
      currencySymbol = str('currencySymbol', r'$');
      pricingTier = pricingTierFromName(str('pricingTier', ''));
      fillDeviceDefaultsOnLoad = saved['fillDeviceDefaultsOnLoad'] is bool
          ? saved['fillDeviceDefaultsOnLoad']
          : true;
      confirmBeforeDelete = saved['confirmBeforeDelete'] is bool
          ? saved['confirmBeforeDelete']
          : true;
      snapDiagramsToGrid = saved['snapDiagramsToGrid'] is bool
          ? saved['snapDiagramsToGrid']
          : false;
      showDiagramGrid =
          saved['showDiagramGrid'] is bool ? saved['showDiagramGrid'] : true;
      autosaveEnabled =
          saved['autosaveEnabled'] is bool ? saved['autosaveEnabled'] : true;
      autosaveMinutes = _sanitizeAutosaveMinutes(saved['autosaveMinutes']);
      roomScanDepth = _sanitizeRoomScanDepth(saved['roomScanDepth']);

      // MIGRATION: the Auris style used to be stored as one value per accent
      // ('amber' | 'teal' | 'magenta'); it is now 'auris' + aurisColor.
      const legacyAuris = {
        'amber': 'F0A500',
        'teal': '35E0C0',
        'magenta': 'E0409A',
      };
      if (legacyAuris.containsKey(themeStyle)) {
        aurisColor = legacyAuris[themeStyle]!;
        themeStyle = 'auris';
      }

      // FIRST-RUN CHECK: only ask for file locations when setup was never
      // completed. Once 'initialSetupComplete' is saved, this is bypassed
      // on every later launch. (Existing installs that already have any
      // path saved are treated as set up — no nagging after an update.)
      final bool setupDone = saved['initialSetupComplete'] == true;
      final bool hasAnySavedPath = rootFolderPath.isNotEmpty ||
          modulesPath.isNotEmpty ||
          processorsFilePath.isNotEmpty ||
          buildingsFilePath.isNotEmpty ||
          templateFilePath.isNotEmpty ||
          avDevicesFilePath.isNotEmpty;
      if (setupDone || hasAnySavedPath) {
        firstRunSetupNeeded = false;
        // Grandfather existing installs in so they're never asked.
        _initialSetupComplete = true;
      } else {
        firstRunSetupNeeded = true;
      }

      // Write the file back immediately so app_config.json exists in the
      // root folder (with defaults or the imported values) from now on.
      await _persistSettings();

      // Load the GUI field schema (falls back to built-in defaults on any error)
      await loadUiSchema();
      // Load the legacy key translation map (empty/no-op when no file exists)
      await loadKeyMap();
      // Load the AV connector library (built-ins when no file exists)
      await loadAvDeviceLibrary();
      // Load the AV flow rule book (built-ins when no file exists)
      await loadFlowRules();
      // Load the labor rate card (built-in roles when no file exists)
      await loadLaborRates();
      // Load the base cost card (every category unset when no file exists)
      await loadBaseCosts();

      // Load files into memory on boot. The loaders resolve their own
      // default paths (Root Folder / working directory) when no explicit
      // path is set, so processors.json and buildings.json are read on
      // startup even on a fresh install with everything left blank.
      await loadBuildingsList();
      await loadProcessorsList();

      // Warm the python module caches in the background so the keep-alive /
      // input dropdowns are instant the first time a device tab is opened.
      // Uses the effective path (default: <root>/devices) and exits quietly
      // if that folder doesn't exist yet.
      // ignore: unawaited_futures
      preloadAllModules();

    } catch (e, stack) {
      AppLogger.logError("Startup Initialization Error", e, stack);
    } finally {
      // Update the UI once all heavy lifting is done
      settingsLoaded = true; // Safe for the UI to show (or skip) first-run setup
      // The interval is a setting, so the clock can only start once the
      // settings have been read.
      _restartAutosaveTimer();
      notifyListeners(); 
    }
  }

  /// Prompts the user to pick an existing config file and loads it.
  /// Automatically creates a backup of the original file if migration is needed.
  Future<bool> loadExistingConfig() async {
    FilePickerResult? result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final picked = result?.files.single.path;
    if (picked == null) return false;
    return openConfigAtPath(picked);
  }

  /// Loads the config at [file] — everything [loadExistingConfig] does once
  /// the picker has closed.
  ///
  /// Its own method because opening a room is no longer always a file dialog:
  /// a project names its rooms, and switching to one of them has to go through
  /// exactly the same pipeline — the same backup, the same migration, the same
  /// change log — or a room opened from the project would be a differently
  /// loaded room from the same room opened by hand.
  Future<bool> openConfigAtPath(String file) async {
    try {
      final f = File(file);
      final originalContents = await f.readAsString();
      final Map<String, dynamic> parsedConfig = jsonDecode(originalContents);

      // Remember the working file so 'Apply Changes' in the raw editor can
      // save back to it directly.
      currentConfigPath = f.path;

      // The room on screen is not the room the last target named.
      clearDeploymentTarget();

      await _processLoadedConfig(
        originalContents: originalContents,
        parsedConfig: parsedConfig,
        backupDirectory: f.parent.path,
        sourceLabel: f.path,
        // Change log named after the opened file: <name>_backup_log.txt
        changeLogBaseName: path.basenameWithoutExtension(f.path),
      );
      // The room now matches the file it came from, so the unsaved-work
      // check has a baseline to compare against.
      markRoomSaved();
      // The config half of the recovery check. The sidecars are not in yet, so
      // this pass only reports and never retires — see checkForRoomRecovery.
      checkForRoomRecovery(sidecarsLoaded: false);
      AppLogger.logInfo("Loaded existing config from ${f.path}");
      return true;
    } catch (e, stack) {
      AppLogger.logError("Failed to load existing config", e, stack);
      return false;
    }
  }

  /// Downloads /config.json from the processor's root folder over SFTP,
  /// prompts the user for a NEW working file location, writes a backup of the
  /// exact downloaded original, and loads the config into memory for editing.
  Future<bool> downloadConfigFromProcessor({
    required String ipAddress,
    required String password,
    required Function(String) onStatusUpdate,
  }) async {
    Directory? tempDir;
    try {
      tempDir = await Directory.systemTemp.createTemp('deployment_app_dl_');
      final tempPath = path.join(tempDir.path, 'config.json');

      final sftpClient = SftpLogger();
      final ok = await sftpClient.downloadProcessorFile(
        ipAddress: ipAddress,
        password: password,
        // Remote path / credentials from App Config > Processor Connection
        remoteFilename: sftpRemoteConfigPath,
        outputPath: tempPath,
        username: sftpUsername,
        port: effectiveSftpPort,
        onStatusUpdate: onStatusUpdate,
      );
      if (!ok) return false;

      final originalContents = await File(tempPath).readAsString();
      final Map<String, dynamic> parsedConfig = jsonDecode(originalContents);

      // Backup base name comes from the Active Deployment Target dropdown
      // (e.g. roomName 'BSS103' or 'BSS 103' -> 'BSS103_old_config.json').
      // Sanitized for filesystem safety; blank when no room is selected.
      final String backupBase = (selectedProcessor?['roomName']?.toString() ?? '')
          .replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '');

      // Prompt for where the NEW (editable) working copy should live.
      // Per convention, the working file is always plain config.json.
      onStatusUpdate('System: Choose where to save the new working copy...');
      String? savePath = await FilePicker.saveFile(
        dialogTitle: 'Save Downloaded Config As (new working file)',
        fileName: 'config.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (savePath == null) {
        onStatusUpdate('System: Download canceled (no save location chosen).');
        return false;
      }
      // The dialog hands back exactly what was typed, so a name entered without
      // an extension would land as a file Windows can't associate with JSON.
      if (!savePath.toLowerCase().endsWith('.json')) savePath += '.json';

      // Write the working copy exactly as downloaded; your edits are exported later
      await File(savePath).writeAsString(originalContents);

      // Remember the working file so 'Apply Changes' in the raw editor can
      // save back to it directly.
      currentConfigPath = savePath;

      // Backup the pristine download next to the working copy, then load it
      await _processLoadedConfig(
        originalContents: originalContents,
        parsedConfig: parsedConfig,
        backupDirectory: File(savePath).parent.path,
        sourceLabel: 'SFTP download from $ipAddress -> $savePath',
        backupBaseName: backupBase.isNotEmpty ? backupBase : null,
        // Change log matches the backup name: e.g. BSS103_backup_log.txt
        changeLogBaseName: backupBase.isNotEmpty ? backupBase : null,
      );

      onStatusUpdate('System: Config downloaded, backed up, and loaded for editing.');
      return true;
    } catch (e, stack) {
      AppLogger.logError("Failed to download config from processor $ipAddress", e, stack);
      onStatusUpdate('System Error: Failed to process downloaded config - $e');
      return false;
    } finally {
      try { if (tempDir != null && await tempDir.exists()) await tempDir.delete(recursive: true); } catch (_) {}
    }
  }

  /// Shared pipeline for any incoming config (local file or SFTP download):
  /// backs up the original, migrates missing keys, flags non-template items,
  /// writes the migration log file, and warms the module caches.
  Future<void> _processLoadedConfig({
    required String originalContents,
    required Map<String, dynamic> parsedConfig,
    required String backupDirectory,
    required String sourceLabel,
    String? backupBaseName, // e.g. 'BSS103' from the Active Deployment Target
    String? changeLogBaseName, // base for the per-load change log file name
  }) async {
    systemLogs.clear(); // Clear old logs on new load
    _prunedSystemKeys.clear(); // Belongs to the room being replaced
    _prunedSourceInputs.clear();
    _omittedConfigKeys.clear();

    roomConfig = parsedConfig;

    // Snapshot the file EXACTLY as parsed, before any conversion step. Every
    // later stage mutates roomConfig in place, so this deep copy is the only
    // record of what the room looked like on disk — the provenance coloring
    // and the preview's per-change reject both diff against it.
    _originalLoadedConfig = jsonDecode(jsonEncode(parsedConfig)) as Map<String, dynamic>;
    Map<String, String> sectionRenames = const {};
    List<ConversionConflict> conflicts = const [];

    // --- LEGACY KEY MAPPING (key_map.json) ---
    // Translate old section/property names (e.g. CAMERA1DEVICE.IPADDRESS ->
    // CAMERADEVICE_1.ip_address) BEFORE the template migration runs, so the
    // rest of the pipeline only ever sees current-schema keys. The pristine
    // original text is backed up right after this step (naming the backup
    // needs the mapped room identity).
    if (keyMap.ruleCount > 0) {
      // Canonical key list powers auto-case-normalization: any legacy
      // property whose lowercased/underscore-stripped form matches a current
      // key gets renamed without needing an explicit rule for every variant.
      final canonicalKeys = <String>{
        ...ConfigDictionary.descriptions.keys,
        ...uiSchema.exactKeys,
      }.toList();
      final result = keyMap.apply(roomConfig, canonicalKeys: canonicalKeys);
      // Kept even when nothing else changed: the renames are how the
      // provenance diff lines converted sections up with the original file.
      sectionRenames = result.sectionRenames;
      conflicts = result.conflicts;
      if (result.changed) {
        roomConfig = result.config;
        systemLogs.add("KEY MAPPING: Translated ${result.changes.length} legacy item(s) using ${keyMap.source}");
        systemLogs.addAll(result.changes);
        systemLogs.add("--------------------------------------------------");
        AppLogger.logInfo("Key map applied ${result.changes.length} change(s) to loaded config.");
      }
    }

    // --- AUTOMATIC BACKUP (pristine original text) ---
    // Runs AFTER key mapping so the file name can use the room identity that
    // is now inside the config: gve_bldg abbreviation + gve_room, e.g.
    // 'BSS103_old_config.json' — even for legacy files that stored them as
    // SYSTEM.GVE_BLDG / GVE_ROOM. The CONTENT is still the untouched original.
    try {
      String backupFileName;
      if (backupBaseName != null && backupBaseName.isNotEmpty) {
        // Caller supplied a name (SFTP download: the processor dropdown's
        // room name), e.g. BSS103_old_config.json
        backupFileName = '${backupBaseName}_old_config.json';
      } else {
        String bldg = "UNKNOWN";
        String room = "000";
        final setup = roomConfig['SYSTEM_SETUP'];
        if (setup is Map) {
          bldg = setup['gve_bldg']?.toString() ?? "UNKNOWN";
          room = setup['gve_room']?.toString() ?? "000";
        }
        // Short abbreviation + room, sanitized for the filesystem: BSS103
        final base = '${bldgAbbreviation(bldg)}$room'
            .replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '');
        backupFileName = '${base}_old_config.json';
      }
      final backupFilePath = path.join(backupDirectory, backupFileName);

      // Write the exact original string to disk so no formatting is lost
      await File(backupFilePath).writeAsString(originalContents);

      AppLogger.logInfo("Created backup of original config at $backupFilePath");
      // Keep the backup notice at the TOP of the acknowledgement
      systemLogs.insert(0, "BACKUP SAVED: Original file preserved as '$backupFileName'");
      systemLogs.insert(1, "--------------------------------------------------");
    } catch (backupError) {
      AppLogger.logError("Failed to create backup file", backupError);
      systemLogs.insert(0, "WARNING: Failed to generate local backup file.");
    }
    // ------------------------------

    // Check for missing keys and patch them
    _validateAndMigrateConfig();

    // --- BUILDING CODE NORMALIZATION ---
    // gve_bldg holds the building CODE (e.g. 'BSS'). Older configs stored the
    // ALL CAPS full name — convert it via buildings.json and log the change.
    final setupBlock = roomConfig['SYSTEM_SETUP'];
    if (setupBlock is Map) {
      final bldgVal = setupBlock['gve_bldg']?.toString() ?? '';
      if (bldgVal.isNotEmpty && buildings.containsKey(bldgVal)) {
        final code = buildings[bldgVal].toString();
        // Some codes equal their name (e.g. GSCI) — nothing to convert then
        if (code != bldgVal) {
          setupBlock['gve_bldg'] = code;
          systemLogs.add(
              "BUILDING CODE: gve_bldg '$bldgVal' converted to building code '$code' (from buildings.json).");
        }
      }
    }

    // --- DEVICE DEFAULTS FILL (ui_schema.json "device_defaults") ---
    // Optionally ensure every device block carries its type's baseline
    // properties (e.g. a DSP without its audio group numbers). Existing
    // values are never touched; each addition is reported below.
    if (fillDeviceDefaultsOnLoad) {
      final int filled = _fillDeviceDefaults();
      if (filled > 0) {
        systemLogs.add(
            "DEFAULTS: Added $filled missing device propert${filled == 1 ? 'y' : 'ies'} from ui_schema.json device_defaults.");
      }
    }

    // --- MODULE RESOLUTION ---
    // A converted room often arrives with the model but no module. Look the
    // module up by model, and put every module value into the
    // modules.device.<name> form the processor imports.
    await _resolveDeviceModules();

    // --- MODULE VALUE AUDITS ---
    // Every device now has its module, so the family defaults the key map
    // injected can be checked against what that model's driver implements: the
    // keep-alive is corrected from the module, module_states values (a
    // projector's input) are flagged for the tech to decide.
    await validateKeepAliveCommands();
    await validateModuleStateFields();

    // Undo family defaults the resolved model doesn't use (a scaler's group_*
    // audio group numbers). Runs after the audits so the log reads in order:
    // what was corrected, what was flagged, then what was dropped.
    applyModuleOmissions();

    // Undo any opt-in setting the migration steps above added but the loaded
    // file never carried (ENVIRONMENT.traceback_allowed).
    removeUninvitedOptIns(_originalLoadedConfig);

    // Retire the redundant per-outlet '_action' key, carrying a legacy
    // 'Reboot' over to '_reboot_only' so the outlet still cycles. Runs after
    // the companion keys that create '_reboot_only', and reads the loaded file
    // rather than the working config to tell a real setting from that default.
    foldOutletActionIntoRebootOnly(_originalLoadedConfig);

    // Drop the input_* keys this room's sources do not entitle it to — a
    // legacy file retyped down to four sources still carries the DVD and
    // Blu-ray input numbers, and a room with no cameras still carries theirs.
    // Before the provenance diff, so the removals are part of the conversion
    // the preview reports rather than a change nobody was told about.
    final int strippedInputs = pruneUnusedSourceInputs();
    if (strippedInputs > 0) {
      systemLogs.add(
          "DEFAULTS: Removed $strippedInputs input key(s) this room has no "
          "source for (gui_tab_type / dev_cameras).");
    }

    // Auto-generate the Title Case full room name when gve_bldg (code like
    // 'BSS' OR a legacy full name) resolves against buildings.json — so a
    // converted legacy file lands with 'Behavioral And Social Science 103'
    // instead of the 'Legacy Room Update' placeholder.
    final String? nameBefore =
        roomConfig['SYSTEM_SETUP']?['gui_full_room_name']?.toString();
    if (isKnownBuilding) {
      updateFullRoomName();
      final String? nameAfter =
          roomConfig['SYSTEM_SETUP']?['gui_full_room_name']?.toString();
      if (nameAfter != null && nameAfter != nameBefore) {
        systemLogs.add(
            "AUTO-NAME: gui_full_room_name set to '$nameAfter' (gve_bldg matched buildings.json).");
      }
    }

    // --- CONVERSION PROVENANCE ---
    // Every value-changing step has run by now, so diffing against the parsed
    // original gives the full picture: which values came from the old file
    // (orange), which the conversion wrote (white), and the reversible list
    // the preview offers per change.
    // Kept for the driver-defaults review's "Original File" comparison, which
    // has to line a converted block up with the section it came from long
    // after the provenance colouring has been read and forgotten.
    lastSectionRenames = sectionRenames;
    computeConversionProvenance(sectionRenames, conflicts);

    // Warn (never auto-change) when more device blocks exist than the dev_
    // counts allow — extra blocks are hidden in tabs and pruned on export,
    // which is normal for templates but surprising for migrated legacy rooms.
    _auditDeviceCounts();

    // Flag anything in the loaded config that does not exist in the default template
    final template = await _readDefaultTemplate();
    if (template != null) {
      flagUnknownKeys(template);
    } else {
      systemLogs.add("NOTE: No default template available to audit against (set one in App Config).");
    }

    // Persist a permanent record of every change added/flagged during the
    // load so there is an audit trail beyond the in-memory dialog.
    await AppLogger.logMigration(sourceLabel, List<String>.from(systemLogs));

    // --- PER-LOAD CHANGE LOG FILE ---
    // When this load actually changed or flagged anything, write the full
    // acknowledgement next to the backup, named to match it:
    //   SFTP download -> BSS103_backup_log.txt (processor dropdown room)
    //   local open    -> <original file name>_backup_log.txt
    final bool hasChanges = systemLogs.any((l) =>
        l.startsWith('KEY MAPPING') ||
        l.startsWith('KEYMAP') ||
        l.startsWith('->') ||
        l.startsWith('SYSTEM MIGRATION') ||
        l.startsWith('CRITICAL') ||
        l.startsWith('FLAGGED') ||
        l.startsWith('COUNT') ||
        l.startsWith('BUILDING CODE') ||
        l.startsWith('DEFAULTS') ||
        l.startsWith('CONFLICT') ||
        l.startsWith('MODULE') ||
        l.startsWith('AUTO-NAME'));
    // The acknowledgement dialog keys off this: a clean re-load of an
    // already-migrated file (backup + OK lines only) shows no dialog.
    lastLoadHadChanges = hasChanges;
    // A fresh load is a fresh conversion to deal with, so the count comes
    // back — which is the other half of clearing it when the work is done.
    conversionAcknowledged = false;
    if (hasChanges) {
      String logBase = changeLogBaseName ?? backupBaseName ?? '';
      if (logBase.isEmpty) {
        // Fall back to the same identifiers the backup name uses
        final bldg = roomConfig['SYSTEM_SETUP']?['gve_bldg']?.toString() ?? 'UNKNOWN';
        final room = roomConfig['SYSTEM_SETUP']?['gve_room']?.toString() ?? '000';
        logBase = '${bldgAbbreviation(bldg)}_$room';
      }
      final changeLogPath = path.join(backupDirectory, '${logBase}_backup_log.txt');
      await AppLogger.writeChangeLog(
          changeLogPath, sourceLabel, List<String>.from(systemLogs));
      systemLogs.add("CHANGE LOG: Details saved to '${logBase}_backup_log.txt'");
    }

    _bumpConfigRevision(); // Repaint every tab with the newly loaded room
    _preloadModulesFromConfig(); // Warm the parser caches for referenced modules
    notifyListeners();
  }

  /// Reads the default template config (the file set via 'Load Template',
  /// falling back to config.json in the root folder / working directory)
  /// without touching state.
  Future<Map<String, dynamic>?> _readDefaultTemplate() async {
    final String tplPath = effectiveTemplateFilePath;
    try {
      final f = File(tplPath);
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (e, stack) {
      AppLogger.logError("Failed to read default template for audit", e, stack);
      return null;
    }
  }

  /// Flags any sections/properties in the loaded config that are NOT part of
  /// the default template, so leftovers and custom keys show up in the log.
  @visibleForTesting
  void flagUnknownKeys(Map<String, dynamic> templateConfig) {
    // Strip trailing digits so PROJECTORDEVICE_2 compares against PROJECTORDEVICE_1
    String normalize(String key) => key.replaceFirst(RegExp(r'\d+$'), '');
    final Set<String> templateFamilies = templateConfig.keys.map(normalize).toSet();
    int flagged = 0;

    // 1. Top-level sections unknown to the template
    roomConfig.forEach((key, value) {
      if (uiSchema.isRuntimeWritten(key)) return; // the processor's own
      if (!templateFamilies.contains(normalize(key))) {
        systemLogs.add("FLAGGED: Section '$key' does not exist in the default config template.");
        flagged++;
      }
    });

    // 2. SYSTEM_SETUP properties unknown to the template
    if (roomConfig['SYSTEM_SETUP'] is Map && templateConfig['SYSTEM_SETUP'] is Map) {
      final tplSetup = templateConfig['SYSTEM_SETUP'] as Map;
      (roomConfig['SYSTEM_SETUP'] as Map).forEach((key, value) {
        if (uiSchema.isRuntimeWritten('SYSTEM_SETUP', key.toString())) return;
        if (!tplSetup.containsKey(key)) {
          systemLogs.add("FLAGGED: SYSTEM_SETUP property '$key' is not in the default config template.");
          flagged++;
        }
      });
    }

    // 3. Device block properties unknown to the template's matching device family
    roomConfig.forEach((key, value) {
      if (key == 'SYSTEM_SETUP' || value is! Map) return;
      final family = normalize(key);
      final tplBlockKey = templateConfig.keys.firstWhere(
        (k) => normalize(k) == family && templateConfig[k] is Map,
        orElse: () => '',
      );
      if (tplBlockKey.isEmpty) return; // Whole section already flagged above
      final tplBlock = templateConfig[tplBlockKey] as Map;
      value.forEach((prop, _) {
        if (uiSchema.isRuntimeWritten(key, prop.toString())) return;
        if (!tplBlock.containsKey(prop)) {
          systemLogs.add("FLAGGED: '$key.$prop' is not in the default config template.");
          flagged++;
        }
      });
    });

    if (flagged > 0) {
      systemLogs.add("TEMPLATE AUDIT: $flagged item(s) in this config are not part of the default template.");
    } else {
      systemLogs.add("TEMPLATE AUDIT: All items match the default config template.");
    }
  }

  /// Fills device blocks with any missing properties from the schema's
  /// "device_defaults" section (see UiSchema.defaultsFor). Existing values
  /// always win. Logs one line per added property; returns how many were
  /// added across the whole config.
  int _fillDeviceDefaults() {
    int filled = 0;
    roomConfig.forEach((sectionKey, block) {
      if (sectionKey == 'SYSTEM_SETUP' || block is! Map) return;
      final defaults = uiSchema.defaultsFor(sectionKey);
      final live = block.map((k, v) => MapEntry(k.toString(), v));
      defaults.forEach((prop, defaultValue) {
        if (block.containsKey(prop)) return;
        // A family default must never hand a device a property its connection
        // can't use ("hideWhen") — a Network projector has no serial port.
        if (uiSchema.isHiddenFor(prop, live, sectionKey: sectionKey)) return;
        block[prop] = defaultValue;
        systemLogs.add(
            "-> Added missing device property: '$sectionKey.$prop' (Default: '$defaultValue')");
        filled++;
      });
    });
    return filled;
  }

  /// Scans the loaded configuration against baseline defaults and patches missing keys.
  void _validateAndMigrateConfig() {
    // If SYSTEM_SETUP is entirely missing, create it
    if (!roomConfig.containsKey('SYSTEM_SETUP')) {
      roomConfig['SYSTEM_SETUP'] = <String, dynamic>{};
      systemLogs.add("CRITICAL: Added missing 'SYSTEM_SETUP' root block.");
    }

    final systemSetup = roomConfig['SYSTEM_SETUP'] as Map<String, dynamic>;

    // Define the baseline schema needed for the current template to function.
    // Values come from the UI schema's "system_defaults", editable in
    // ui_schema.json without a rebuild. The dev_ count keys are handled
    // separately below — they can't just default to "0".
    final Map<String, dynamic> baselineDefaults = {...uiSchema.systemDefaults};

    int additions = 0;

    // Check existing keys against the baseline
    baselineDefaults.forEach((key, defaultValue) {
      if (systemSetup.containsKey(key)) return;
      // A baseline the room has no use for is not a baseline. "hideWhen" is
      // the question every other fill path already asks — the device pass, the
      // module defaults, Check Defaults — and this one used to be the
      // exception, which is why a mode-only key could never be a default at
      // all. Read against SYSTEM_SETUP as it stands, so the room is judged on
      // what its own file says: display_min_volume is a baseline for a room
      // whose volume lands on the display and nothing at all in one whose
      // volume goes to a DSP.
      if (uiSchema.isHiddenFor(key, systemSetup, sectionKey: 'SYSTEM_SETUP')) {
        return;
      }
      systemSetup[key] = defaultValue;
      systemLogs.add("-> Added missing property: '$key' (Default: '$defaultValue')");
      additions++;
    });

    // --- DEVICE COUNTS ---
    // A legacy file can carry device blocks for a family it never declared a
    // count for (AJH125B has a SWITCHERDEVICE but no dev_Switchers). Injecting
    // "0" there silently drops real hardware: the tabs hide the block, the
    // schematic skips it and export prunes it, so the switcher vanishes even
    // though the conversion kept it. Derive the count from the blocks that are
    // actually in the config, which lands on "0" only when there are none.
    for (final t in uiSchema.deviceTypes) {
      if (systemSetup.containsKey(t.countKey)) continue; // the file said so
      final int blocks = roomConfig.keys
          .where((k) =>
              k.startsWith(t.prefix) &&
              int.tryParse(k.substring(t.prefix.length)) != null &&
              roomConfig[k] is Map)
          .length;
      systemSetup[t.countKey] = blocks.toString();
      additions++;
      if (blocks == 0) {
        systemLogs.add("-> Added missing property: '${t.countKey}' (Default: '0')");
      } else {
        systemLogs.add(
            "COUNT RECOVERED: '${t.countKey}' was missing from the file - set to "
            "'$blocks' from the ${t.prefix}* block(s) already present, so the "
            "hardware isn't dropped on export.");
      }
    }

    // Standalone feature blocks from ui_schema.json "section_defaults"
    // (e.g. METRICS_CONFIG): create the section when it is missing entirely,
    // then fill in any properties it doesn't have. Existing values are never
    // touched — the same contract as the SYSTEM_SETUP pass above.
    uiSchema.sectionDefaults.forEach((sectionKey, defaults) {
      final existing = roomConfig[sectionKey];
      if (existing != null && existing is! Map) {
        // Something else lives under that name — never clobber it silently
        systemLogs.add(
            "FLAGGED: '$sectionKey' exists but is not a settings block, so its defaults were skipped.");
        return;
      }
      if (existing == null) {
        roomConfig[sectionKey] = <String, dynamic>{};
        systemLogs.add("-> Added missing section: '$sectionKey'");
      }
      final section = roomConfig[sectionKey] as Map;
      defaults.forEach((key, defaultValue) {
        if (!section.containsKey(key)) {
          section[key] = defaultValue;
          systemLogs.add(
              "-> Added missing property: '$sectionKey.$key' (Default: '$defaultValue')");
          additions++;
        }
      });
    });

    if (additions > 0) {
      String summary = "SYSTEM MIGRATION: Added $additions missing schema properties to match current template standards.";
      systemLogs.insert(2, summary); // Insert summary right below the backup notification
      AppLogger.logInfo(summary);
    } else {
      systemLogs.add("OK: Loaded config already matches the current template schema. No changes required.");
    }
  }

  /// Creates a new config from the default template (set via 'Load Template'),
  /// falling back to config.json in the root folder / working directory.
  /// Devices set to 0. This is the ONLY point where the template file is
  /// actually read into memory.
  Future<bool> createNewConfig() async {
    final String baseConfigPath = effectiveTemplateFilePath;

    try {
      final file = File(baseConfigPath);
      
      if (!await file.exists()) {
        AppLogger.logError(
            "Template config not found at $baseConfigPath. "
            "Place config.json in the root folder or set a Template file in App Config.");
        return false;
      }

      final contents = await file.readAsString();
      roomConfig = jsonDecode(contents);

      // Fresh session: no working file yet, so the raw editor's Apply won't
      // overwrite the previously opened file (or the template) by mistake.
      currentConfigPath = '';

      // And no processor, for the same reason: a room built from the template
      // has never been deployed anywhere, least of all to whichever room was
      // selected before it.
      clearDeploymentTarget();

      // Built from the template, not converted — every value is "written",
      // so there is nothing to color orange.
      _clearConversionProvenance();

      // AND NOTHING WAS CONVERTED, so the previous room's conversion must not
      // still be on the toolbar. The change log, the "this file needed
      // converting" flag and the acknowledgement state all belong to the file
      // that was open before this one: left standing, the Convert button on a
      // brand new config opened the log of the last room that was migrated —
      // "BACKUP SAVED: Original file preserved as 'BSS112_old_config.json'" —
      // which reads as this config having been converted from that room.
      systemLogs.clear();
      lastLoadHadChanges = false;
      conversionAcknowledged = false;

      // Nothing carried over from the previous room can be restored into this
      // one — the stash is per-config.
      _prunedSystemKeys.clear();
      _prunedSourceInputs.clear();
      _omittedConfigKeys.clear();

      // Default all hardware counts to 0 (families from the UI schema's
      // device_types, so new dev_ keys added there are covered too)
      if (roomConfig.containsKey('SYSTEM_SETUP')) {
        final setup = roomConfig['SYSTEM_SETUP'];
        final deviceKeys =
            uiSchema.deviceTypes.map((t) => t.countKey).toList();

        for (var key in deviceKeys) {
          if (setup.containsKey(key)) {
            setup[key] = "0";
          }
        }

        // A new file starts with no hardware at all, so the SYSTEM_SETUP
        // settings that only configure a family's hardware go with it — a room
        // with no power controller carries no power1_outlet_* names. The
        // template's values are stashed, so choosing a Power Controller count
        // in the wizard puts them straight back.
        for (final key in deviceKeys) {
          _pruneSystemKeysForCount(key, 0);
        }

        // Same for the source inputs: a template's five-source room starts
        // with no cameras, so the camera input numbers go with them and come
        // back the moment the wizard puts a camera in the room.
        pruneUnusedSourceInputs();
      }

      // Prune existing devices based on the new 0 counts
      roomConfig = _pruneConfig(roomConfig);

      // Give a new file the same schema baseline a LOADED one gets. Without
      // this the two paths disagree: ENVIRONMENT (the ControlScript
      // pro/xi profile) is described in ui_schema.json and injected on load,
      // so a converted room had the setting while a brand new one silently
      // had no ENVIRONMENT block at all. Template values always win — this
      // only fills what the template does not carry.
      _applySchemaBaseline();

      // A brand new room starts with blank diagrams — there is no working
      // file for a sidecar to sit next to yet.
      _resetSchematicLayout();
      _resetAvFlow();

      _bumpConfigRevision(); // Repaint every tab: this is a different room now
      _preloadModulesFromConfig(); // Warm the parser caches for referenced modules
      notifyListeners();
      AppLogger.logInfo("New config created from template: $baseConfigPath");
      return true;
    } catch (e, stack) {
      AppLogger.logError("Failed to create new config", e, stack);
      return false;
    }
  }

  /// Puts the room away, leaving nothing open.
  ///
  /// THE COUNTERPART OF CLOSING A JOB, which this app has had for a long time
  /// while a room could only ever be REPLACED - by another room, or by a new
  /// one from the template. There was no way back to an empty session, so
  /// somebody who had finished with a room and wanted the start screen had to
  /// close the whole application to get it.
  ///
  /// It resets exactly what [createNewConfig] resets, and then does not read a
  /// template: everything that belongs to the room that was open goes with it -
  /// the file it came from, the processor it was going to, the conversion log,
  /// the stashed keys and both drawings. A leftover here is worse than useless,
  /// because it would show up as a fact about whichever room is opened next.
  ///
  /// SAYS NOTHING ABOUT UNSAVED WORK - that is the caller's to ask, before
  /// this is reached. See [closeRoomFile].
  void closeRoom() {
    final was = currentConfigPath;
    roomConfig = {};
    currentConfigPath = '';
    clearDeploymentTarget();
    _clearConversionProvenance();
    systemLogs.clear();
    lastLoadHadChanges = false;
    conversionAcknowledged = false;
    _prunedSystemKeys.clear();
    _prunedSourceInputs.clear();
    _omittedConfigKeys.clear();
    _resetSchematicLayout();
    _resetAvFlow();
    _bumpConfigRevision();
    AppLogger.logInfo(
      was.isEmpty ? 'Room closed.' : 'Room closed ($was).',
    );
    notifyListeners();
  }

  /// Fills anything the UI schema calls a baseline that the working config is
  /// missing — SYSTEM_SETUP "system_defaults" and whole "section_defaults"
  /// blocks (ENVIRONMENT, METRICS_CONFIG). Existing values are NEVER touched,
  /// so a template that ships its own copy keeps it.
  ///
  /// The load path does this as part of the migration (with each addition
  /// written to the change log); this is the same contract for New Config,
  /// where there is no migration log to write to — additions go to the app log
  /// instead. Returns how many properties were added.
  int _applySchemaBaseline() {
    int added = 0;
    final setup = roomConfig['SYSTEM_SETUP'];
    if (setup is Map) {
      uiSchema.systemDefaults.forEach((key, defaultValue) {
        if (setup.containsKey(key)) return;
        // Same "hideWhen" gate the load path applies, rebuilt each time so a
        // baseline written a moment ago is part of what the next one is
        // judged against.
        final live = setup.map((k, v) => MapEntry(k.toString(), v));
        if (uiSchema.isHiddenFor(key, live, sectionKey: 'SYSTEM_SETUP')) return;
        setup[key] = defaultValue;
        added++;
      });
    }

    uiSchema.sectionDefaults.forEach((sectionKey, defaults) {
      final existing = roomConfig[sectionKey];
      // Something else already lives under that name — never clobber it.
      if (existing != null && existing is! Map) return;
      if (existing == null) roomConfig[sectionKey] = <String, dynamic>{};
      final section = roomConfig[sectionKey] as Map;
      defaults.forEach((key, defaultValue) {
        if (!section.containsKey(key)) {
          section[key] = defaultValue;
          added++;
        }
      });
    });

    if (added > 0) {
      AppLogger.logInfo(
          "New config: added $added schema baseline propert${added == 1 ? 'y' : 'ies'} "
          "the template did not carry (ui_schema.json system_defaults / section_defaults).");
    }
    return added;
  }

  /// Updates a setting in memory and saves app_config.json simultaneously
  Future<void> updateSetting(String key, String value) async {
    switch (key) {
      case 'modulesPath':
        modulesPath = value;
        // Path changed: stale caches are invalid; rebuild them in the background
        _moduleCommandsCache.clear();
        _moduleInputsCache.clear();
        _moduleStatesCache.clear();
        availableModules = [];
        // ignore: unawaited_futures
        preloadAllModules();
        break;
      case 'processorsFilePath': 
        processorsFilePath = value; 
        // ignore: unawaited_futures
        loadProcessorsList(); // Re-read from the new (or newly-defaulted) location
        break;
      case 'rootFolderPath': 
        rootFolderPath = value; 
        // The root folder is the default base for every other path, so
        // re-resolve everything that may be running on a default:
        // ignore: unawaited_futures
        loadUiSchema();
        // ignore: unawaited_futures
        loadKeyMap();
        // ignore: unawaited_futures
        loadAvDeviceLibrary();
        // ignore: unawaited_futures
        loadFlowRules();
        // ignore: unawaited_futures
        loadLaborRates();
        // ignore: unawaited_futures
        loadBaseCosts();
        // ignore: unawaited_futures
        loadBuildingsList();
        // ignore: unawaited_futures
        loadProcessorsList();
        if (modulesPath.isEmpty) {
          // Default modules folder (<root>/devices) moved with the root
          _moduleCommandsCache.clear();
          _moduleInputsCache.clear();
          _moduleStatesCache.clear();
          availableModules = [];
          // ignore: unawaited_futures
          preloadAllModules();
        }
        break;
      case 'buildingsFilePath': 
        buildingsFilePath = value; 
        // ignore: unawaited_futures
        loadBuildingsList(); // Re-read from the new (or newly-defaulted) location
        break;
      case 'templateFilePath': 
        templateFilePath = value; 
        break;
      case 'uiSchemaPath':
        uiSchemaPath = value;
        // ignore: unawaited_futures
        loadUiSchema(); // Re-resolve the GUI field definitions from the new path
        break;
      case 'keyMapPath':
        keyMapPath = value;
        // ignore: unawaited_futures
        loadKeyMap(); // Re-resolve the legacy key translation rules
        break;
      case 'avDevicesFilePath':
        avDevicesFilePath = value;
        // ignore: unawaited_futures
        loadAvDeviceLibrary(); // Re-read the catalog from the new location
        break;
      case 'flowRulesFilePath':
        flowRulesFilePath = value;
        // ignore: unawaited_futures
        loadFlowRules(); // Re-read the rule book from the new location
        break;
      case 'documentationPath':
        documentationPath = value; // PDFs are resolved on demand — no reload
        break;
      case 'sftpUsername':
        sftpUsername = value.trim().isEmpty ? 'admin' : value.trim();
        break;
      case 'sftpPort':
        sftpPort = value.trim().isEmpty ? '22022' : value.trim();
        break;
      case 'sftpRemoteConfigPath':
        sftpRemoteConfigPath =
            value.trim().isEmpty ? '/config.json' : value.trim();
        break;
      case 'themeStyle':
        themeStyle = value; // 'classic' | 'auris'
        break;
      case 'classicColor':
        classicColor = value; // RRGGBB hex from the color picker
        break;
      case 'aurisColor':
        aurisColor = value; // RRGGBB hex from the Auris swatch picker
        break;
      case 'classicSecondary':
        classicSecondary = value; // RRGGBB hex, or '' = Auto
        break;
      case 'textScale':
        textScale = double.tryParse(value) ?? 1.0;
        break;
      case 'currencySymbol':
        // Blank is not a currency; an estimate with no symbol in front of the
        // numbers is a column of bare figures.
        currencySymbol = value.trim().isEmpty ? r'$' : value.trim();
        // The room's estimate carries the symbol it was written with, so the
        // open room follows the setting immediately rather than after a
        // reload.
        avCost.currency = currencySymbol;
        break;
      case 'pricingTier':
        pricingTier = pricingTierFromName(value);
        break;
    }
    notifyListeners();
    await _persistSettings();
  }

  /// (Re)loads key_map.json — the legacy config key translation rules that
  /// run automatically on every config load. If keyMapPath is empty,
  /// key_map.json is searched for next to the executable / working directory.
  /// With no file (or a broken one), mapping is a no-op and loading behaves
  /// exactly as before.
  Future<void> loadKeyMap() async {
    // Explicit path wins; else <root>/key_map.json when it exists there; else
    // '' so ConfigKeyMap.load runs its own working-dir/executable search.
    keyMap = await ConfigKeyMap.load(
        explicitPath: _resolveOptionalFile(keyMapPath, 'key_map.json'));
    notifyListeners();
  }

  /// (Re)loads ui_schema.json so new/changed field definitions appear in the
  /// editor WITHOUT a rebuild. If uiSchemaPath is empty, ui_schema.json is
  /// searched for next to the executable / working directory. On any failure
  /// the built-in defaults stay active and the error is logged.
  Future<void> loadUiSchema() async {
    // Explicit path wins; else <root>/ui_schema.json when it exists there;
    // else '' so UiSchema.load runs its own working-dir/executable search.
    uiSchema = await UiSchema.load(
        explicitPath: _resolveOptionalFile(uiSchemaPath, 'ui_schema.json'));
    notifyListeners();
  }

  /// Swaps in an edited schema document (the Schema Editor's every change).
  ///
  /// Rebuilt from the built-ins with [doc] laid over them, rather than patched
  /// in place: that is exactly what loading the file does, so what the editor
  /// shows after an edit is what the next launch will show.
  void applyUiSchemaDoc(Map<String, dynamic> doc) {
    final source = uiSchema.source;
    uiSchema = UiSchema.fromDoc(doc)..source = source;
    notifyListeners();
  }

  /// Writes the schema document. Returns the file written, or '' on failure.
  ///
  /// The document is the one the editor has been changing — comments and all
  /// — so a save is the file it was read from with the edits in it, not a
  /// regenerated approximation of it.
  Future<String> saveUiSchema() async {
    // The file it was READ from wins over the root-folder default: a schema
    // picked up from the working directory (which is where a dev build finds
    // it) must be saved back there rather than copied into the root folder,
    // leaving two files and no way to tell which one the app is using.
    final target = uiSchemaPath.isNotEmpty
        ? uiSchemaPath
        : (uiSchema.source.startsWith('Built-in')
            ? effectiveUiSchemaPath
            : uiSchema.source);
    try {
      final file = File(target);
      await file.parent.create(recursive: true);
      await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert(uiSchema.rawDoc));
      uiSchema.source = target;
      AppLogger.logInfo('UI schema saved to $target.');
      notifyListeners();
      return target;
    } catch (e, stack) {
      AppLogger.logError('Failed to save ui_schema.json', e, stack);
      return '';
    }
  }

  /// (Re)loads av_devices.json, the connector sets the AV Flow tab draws ports
  /// from and the price list the cost estimate reads. Same contract as
  /// [loadUiSchema]: built-ins stay active on any failure and the error is
  /// logged.
  Future<void> loadAvDeviceLibrary() async {
    avDeviceLibrary = await AvDeviceLibrary.load(
        explicitPath:
            _resolveOptionalFile(avDevicesFilePath, 'av_devices.json'));
    notifyListeners();
  }

  /// Where the Device Editor writes the catalog: the file it was read from
  /// when there is one, otherwise `<root>/av_devices.json` — so a first save
  /// lands next to ui_schema.json and processors.json rather than wherever
  /// the app happened to be launched from.
  ///
  /// The chosen path wins even when nothing has been read from it yet — a
  /// catalog pointed at a share that does not have the file in it yet is a
  /// first save into the share, not a stray copy left in the root folder.
  String get effectiveAvDevicesPath => avDevicesFilePath.isNotEmpty
      ? avDevicesFilePath
      : avDeviceLibrary.filePath.isNotEmpty
          ? avDeviceLibrary.filePath
          : path.join(effectiveRootFolder, 'av_devices.json');

  /// Records in the CATALOG that a product has no control interface at all —
  /// [AvDeviceTemplate.neverControlled] — and writes the catalog straight away.
  ///
  /// THIS IS NOT THE SAME DECISION as excluding a box from the room config.
  /// The two look alike on screen and are worlds apart in scope:
  ///
  ///   * [AvNode.excludeFromControl] / [CostLineItem.noControl] say "this box,
  ///     in this room, is not ours to drive" — an owner-furnished display, the
  ///     building's switch, somebody else's codec. The same product in the
  ///     room next door may well be driven.
  ///   * THIS says "no example of this product, anywhere, ever has a control
  ///     interface" — a passive splitter, a plate, a USB capture stick. It is
  ///     a fact about the product, so it belongs to the catalog, and it stops
  ///     every room that ever draws one from carrying it in the "waiting for a
  ///     control module" list. A warning about something that can never be
  ///     fixed is a warning people learn to scroll past, which is how the real
  ///     ones get missed.
  ///
  /// Saved immediately rather than left dirty. The Catalog tab has its own Save
  /// button and can afford to batch; the Cost and Project tabs do not, and an
  /// edit that lives only in memory until something else happens to write the
  /// file is an edit somebody loses.
  ///
  /// Returns whether anything was written and the sentence to show.
  Future<({bool ok, String message})> setModelNeverControlled(
    String model,
    bool value,
  ) async {
    final name = model.trim();
    if (name.isEmpty) {
      return (
        ok: false,
        message: 'This line has no model on it, so there is no catalog entry '
            'to mark. Give the device a model first.',
      );
    }

    final entry = avDeviceLibrary.templateForModel(name);
    if (entry == null) {
      // Deliberately not created here. An entry conjured out of a quote line
      // would have a model and nothing else — no maker, no part number, no
      // price — and would then shadow the real one when somebody imported it.
      // The Cost tab's "Add to catalog" exists for this and asks for the rest.
      return (
        ok: false,
        message: '"$name" is not in the catalog yet. Add it to the catalog '
            'first, then mark it as never needing a module.',
      );
    }

    if (entry.neverControlled == value) {
      return (
        ok: true,
        message: value
            ? '"$name" is already marked as never needing a control module.'
            : '"$name" already expects a control module.',
      );
    }

    avDeviceLibrary.upsert(entry.copyWith(neverControlled: value));
    final file = await saveAvDeviceLibrary();
    // The catalog is a plain object rather than a listenable, so the pages
    // reading it have to be told.
    avDeviceLibraryChanged();

    AppLogger.logInfo(
      'Catalog: "$name" marked '
      '${value ? 'as never needing a control module' : 'as needing a control '
          'module again'}'
      '${file.isEmpty ? ' (in memory only — the catalog file could not be '
          'written)' : ' and saved to $file'}.',
    );

    if (file.isEmpty) {
      return (
        ok: false,
        message: '"$name" was changed in memory, but the catalog file could '
            'not be written - check the Catalog tab.',
      );
    }
    return (
      ok: true,
      message: value
          ? '"$name" never needs a control module. Every room that draws one '
              'stops reporting it as missing a driver.'
          : '"$name" expects a control module again, so rooms will report it '
              'when it has none.',
    );
  }

  /// Writes the device catalog. Returns the file written, or '' on failure.
  Future<String> saveAvDeviceLibrary() async {
    final saved = await avDeviceLibrary.save(toPath: effectiveAvDevicesPath);
    notifyListeners();
    return saved;
  }

  /// av_flow_rules.json: the file it was read from when there is one, else
  /// `<root>/av_flow_rules.json` — beside ui_schema.json and av_devices.json,
  /// which is where the rest of the app's shared documents live.
  String get effectiveFlowRulesPath =>
      flowRulesFilePath.isNotEmpty
          ? flowRulesFilePath
          : (flowRules.source.startsWith('Built-in')
              ? path.join(effectiveRootFolder, 'av_flow_rules.json')
              : flowRules.source);

  /// (Re)reads the rule book. A room with no rule file draws exactly as it
  /// always did — the built-ins ARE the shipped behaviour.
  Future<void> loadFlowRules() async {
    flowRules = await FlowRules.load(
        explicitPath:
            _resolveOptionalFile(flowRulesFilePath, 'av_flow_rules.json'));
    notifyListeners();
  }

  /// Writes the rule book. Returns the file written, or '' on failure.
  Future<String> saveFlowRules() async {
    final saved = await flowRules.save(effectiveFlowRulesPath);
    notifyListeners();
    return saved;
  }

  /// Replaces the rules in memory (the Flow Rules tab's every edit). Disk is
  /// only touched by Save, so a half-typed rule is not everybody's problem
  /// yet — but the drawing follows immediately, which is the point.
  void applyFlowRules(FlowRules rules) {
    flowRules = rules;
    // The routing pass will not re-run over a room it has already drawn
    // unless something it reads has changed, and the rules are something it
    // reads. Clearing the fingerprint is what lets a rule edit reach the
    // drawing that is already on screen.
    avRoutedFingerprint = '';
    notifyListeners();
  }

  /// labor_rates.json: explicit choice, else `<root>/labor_rates.json`.
  String get effectiveLaborRatesPath =>
      laborRates.filePath.isNotEmpty
          ? laborRates.filePath
          : path.join(effectiveRootFolder, 'labor_rates.json');

  /// (Re)loads the rate card. [explicitPath] opens somebody else's card —
  /// rates are per contract as often as they are per year.
  Future<void> loadLaborRates({String explicitPath = ''}) async {
    laborRates = await LaborRateBook.load(
      explicitPath.isNotEmpty ? explicitPath : effectiveLaborRatesPath,
    );
    notifyListeners();
  }

  /// Writes the rate card. Returns the file written, or '' on failure.
  Future<String> saveLaborRates() async {
    final saved = await laborRates.save(toPath: effectiveLaborRatesPath);
    notifyListeners();
    return saved;
  }

  /// The rate card is a plain object, not a listenable, so every edit path
  /// goes through here rather than each view remembering to notify.
  void laborRatesChanged() => notifyListeners();

  // --- base costs: one typical price per device category -------------------

  /// base_costs.json: explicit choice, else `<root>/base_costs.json`.
  String get effectiveBaseCostsPath => baseCosts.filePath.isNotEmpty
      ? baseCosts.filePath
      : path.join(effectiveRootFolder, 'base_costs.json');

  Future<void> loadBaseCosts({String explicitPath = ''}) async {
    baseCosts = await BaseCostBook.load(
      explicitPath.isNotEmpty ? explicitPath : effectiveBaseCostsPath,
    );
    notifyListeners();
  }

  /// Writes the base cost card. Returns the file written, or '' on failure.
  Future<String> saveBaseCosts() async {
    final saved = await baseCosts.save(toPath: effectiveBaseCostsPath);
    notifyListeners();
    return saved;
  }

  void baseCostsChanged() => notifyListeners();

  /// Something outside this class rewrote the room config — the control-side
  /// prefill is the one that does — so every page reading it repaints.
  ///
  /// A method rather than each caller reaching for [notifyListeners]: that one
  /// is protected, and a caller that forgets leaves a page showing the room as
  /// it was before the write. Which is exactly what the Cost tab's
  /// add-to-config button did: the blocks were created and the row went on
  /// flying its orange flag.
  void roomConfigChanged() => notifyListeners();

  // --- labor lines on this room's estimate ---

  LaborLine addAvCostLabor({String rateId = '', double techs = 1}) {
    final line = LaborLine(
      id: _nextCostId('LABOR_'),
      rateId: rateId.isEmpty
          ? (laborRates.rates.isEmpty ? '' : laborRates.rates.first.id)
          : rateId,
      techs: techs,
    );
    avCost.labor.add(line);
    notifyListeners();
    return line;
  }

  void updateAvCostLabor(LaborLine line) {
    final index = avCost.labor.indexWhere((l) => l.id == line.id);
    if (index < 0) return;
    avCost.labor[index] = line;
    notifyListeners();
  }

  void removeAvCostLabor(String lineId) {
    avCost.labor.removeWhere((l) => l.id == lineId);
    notifyListeners();
  }

  /// Marks the catalog changed so the views that read it repaint. The library
  /// is a plain object rather than a listenable, so every edit path goes
  /// through here instead of each view remembering to notify.
  void avDeviceLibraryChanged() => notifyListeners();

  /// The Python driver module that claims [model], or '' when none does.
  ///
  /// The catalog covers everything you can buy; the module library covers
  /// what the control system can actually drive. The gap between the two is
  /// worth reporting — a display with no module is a display somebody has to
  /// switch on by hand — so the AV report lists it rather than leaving it to
  /// be discovered on site. Matching is case-forgiving for the same reason
  /// module resolution is: people type 'TR311hw' for 'TR311HW'.
  String moduleForModel(String model) {
    final entry = modelEntryFor(model);
    return entry == null ? '' : normalizeModuleName(entry.module);
  }

  /// Validates the template file and registers it as the default WITHOUT
  /// loading its contents into the active room config. The file is only
  /// actually read when 'Create New Config' is selected.
  Future<bool> validateConfigTemplate(String templatePath) async {
    try {
      final file = File(templatePath);
      if (!await file.exists()) {
        AppLogger.logError("Template file not found at $templatePath");
        return false;
      }
      // Parse once to confirm it's valid JSON, but do NOT assign to roomConfig
      jsonDecode(await file.readAsString());
      await updateSetting('templateFilePath', templatePath); // persists to app_config.json
      AppLogger.logInfo("Template validated and set as default: $templatePath");
      return true;
    } catch (e, stack) {
      AppLogger.logError("Error validating config template (invalid JSON?)", e, stack);
      return false;
    }
  }

  /// Loads the buildings.json file to resolve building names. Falls back to
  /// `<root>/buildings.json` when no explicit path has been chosen.
  Future<void> loadBuildingsList() async {
    final String bPath = effectiveBuildingsFilePath;
    try {
      final file = File(bPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        buildings = jsonDecode(content);
        notifyListeners();
        AppLogger.logInfo("Buildings list loaded from $bPath");
      } else if (buildingsFilePath.isEmpty) {
        // Default location simply doesn't have the file yet — not an error.
        AppLogger.logInfo(
            "buildings.json not found at default location ($bPath). "
            "Place it in the root folder or set the path in App Config.");
      } else {
        AppLogger.logError("Buildings file not found at $bPath");
      }
    } catch (e, stack) {
      AppLogger.logError("Failed to load buildings.json", e, stack);
    }
  }

  /// True when the current gve_bldg matches buildings.json — either as the
  /// ALL CAPS full name (new style) or a legacy abbreviation (old configs).
  /// Drives whether gui_full_room_name is auto-generated or manually typed.
  bool get isKnownBuilding {
    final val = roomConfig['SYSTEM_SETUP']?['gve_bldg']?.toString() ?? '';
    if (val.isEmpty) return false;
    return buildings.containsKey(val) || buildings.values.contains(val);
  }

  /// Resolves a building CODE (e.g. 'BSS') to its Title Case full name from
  /// buildings.json ('Behavioral And Social Science'). Longest name wins when
  /// several names share one code (same dedupe rule as the Setup Wizard).
  /// Returns '' when the code is unknown, so callers can fall back cleanly.
  String fullBuildingNameForCode(String code) {
    if (code.isEmpty) return '';
    String fullName = '';
    buildings.forEach((name, c) {
      if (c.toString() == code && name.length > fullName.length) {
        fullName = name;
      }
    });
    return fullName.isEmpty ? '' : _toTitleCase(fullName);
  }

  /// Resolves a building value to its short abbreviation for FILE NAMES only
  /// (so gve_bldg holding 'ARTS & HUMANITIES BUILDING' still yields
  /// 'ARTS_208_config.json'). Falls back to the raw value when unknown.
  String bldgAbbreviation(String bldgValue) {
    if (buildings.containsKey(bldgValue)) return buildings[bldgValue].toString();
    return bldgValue;
  }

  /// Helper method to convert a string to Title Case (e.g., "ARTS & HUMANITIES" -> "Arts & Humanities")
  String _toTitleCase(String text) {
    if (text.isEmpty) return text;
    return text.split(' ').map((word) {
      if (word.isEmpty) return word;
      return word[0].toUpperCase() + word.substring(1).toLowerCase();
    }).join(' ');
  }

  /// Automatically updates the gui_full_room_name in SYSTEM_SETUP.
  /// gve_bldg stores the building CODE from buildings.json (e.g. 'BSS'), and
  /// the generated full room name is the Title Case full building name plus
  /// the room number ('Behavioral And Social Science 103').
  /// If the building is not in buildings.json, the name is left untouched so
  /// the user can type the full room name manually in the wizard.
  void updateFullRoomName() {
    if (roomConfig.containsKey('SYSTEM_SETUP')) {
      String bldgValue = roomConfig['SYSTEM_SETUP']['gve_bldg'] ?? '';
      String roomNum = roomConfig['SYSTEM_SETUP']['gve_room'] ?? '';

      // Resolve the ALL CAPS full name: gve_bldg holds the code (new style,
      // e.g. 'BSS') or a legacy full name (older configs). Longest key wins
      // when several names share one code, matching the wizard's dedupe rule.
      String fullBldgName = '';
      if (buildings.containsKey(bldgValue)) {
        fullBldgName = bldgValue;
      } else {
        buildings.forEach((key, value) {
          if (value == bldgValue && key.length > fullBldgName.length) fullBldgName = key;
        });
      }

      if (fullBldgName.isNotEmpty) {
        roomConfig['SYSTEM_SETUP']['gui_full_room_name'] =
            '${_toTitleCase(fullBldgName)} $roomNum'.trim();
      }
      // Unknown building: leave gui_full_room_name for manual entry
      notifyListeners();
    }
  }

  /// Loads the external processors.json file to populate the room selection
  /// dropdown. Runs on boot; falls back to `<root>/processors.json` when no
  /// explicit path has been chosen.
  Future<void> loadProcessorsList() async {
    final String pPath = effectiveProcessorsFilePath;
    try {
      final file = File(pPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        processors = jsonDecode(content);
        notifyListeners();
        AppLogger.logInfo("Processors list loaded from $pPath");
      } else if (processorsFilePath.isEmpty) {
        // Default location simply doesn't have the file yet — not an error.
        AppLogger.logInfo(
            "processors.json not found at default location ($pPath). "
            "Place it in the root folder or set the path in App Config.");
      } else {
        throw Exception("Processors file not found at path.");
      }
    } catch (e, stack) {
      AppLogger.logError("Failed to load processors.json", e, stack);
    }
  }

  // Toggle theme and save it like every other setting
  Future<void> toggleTheme() async {
    isDarkMode = !isDarkMode;
    notifyListeners();
    await _persistSettings();
  }

  /// Sets the active room context
  void selectProcessor(Map<String, dynamic>? processor) { // <-- UPDATED: Allow null
    selectedProcessor = processor;
    notifyListeners();
  }

  /// Forgets the Active Deployment Target, and says so in the log.
  ///
  /// Called whenever a DIFFERENT room is opened or created. The target is the
  /// room the next upload talks to, and it belongs to the room that was open
  /// when somebody picked it: opening BSS 103 with SSC 210 still selected and
  /// pressing Upload sends this room's config to that room's processor, with
  /// nothing on screen saying so. A target that has to be picked again is the
  /// cheaper mistake.
  ///
  /// NOT called on an SFTP download — that config came off the target, so the
  /// target is exactly right.
  void clearDeploymentTarget() {
    if (selectedProcessor == null) return;
    final was = selectedProcessor?['roomName']?.toString() ?? '';
    selectedProcessor = null;
    AppLogger.logInfo(
      'Active Deployment Target cleared'
      '${was.isEmpty ? '' : ' (was $was)'} - a different config is open.',
    );
    notifyListeners();
  }

  /// Resolves the IP/hostname of the Active Deployment Target for SFTP
  /// transfers. Returns '' when no room is selected (UI falls back to prompting).
  String get selectedProcessorIp {
    final p = selectedProcessor;
    if (p == null) return '';
    return (p['ip'] ?? p['ipAddress'] ?? p['ip_address'] ?? p['address'] ?? p['host'] ?? '')
        .toString();
  }
  /// Update a specific nested property for a device (e.g., changing keep_alive_command)
  void updateDeviceValue(String deviceKey, String property, dynamic value) {
    if (roomConfig.containsKey(deviceKey)) {
      // Read before the write, so the com_type handler below can tell a real
      // change of connection style from a re-pick of the same one.
      final previous = roomConfig[deviceKey][property];
      // Pasted multiline text can carry real CR control characters — store
      // the two-character backslash+r sequence instead (saved to disk as \\r,
      // e.g. "TLP\\rPoE"), same as every other write path.
      if (value is String && value.contains('\r')) {
        value = value.replaceAll('\r\n', r'\r').replaceAll('\r', r'\r');
      }
      // The config always stores the import path the processor uses —
      // 'modules.device.<file stem>' — however the value arrived (picked from
      // the list, typed by hand, or resolved from a .py file). Normalizing on
      // the way in is what keeps the prefix on a module chosen for a NEW
      // device, not just on one rewritten during a load.
      if (property == 'module' && value is String) {
        value = normalizeModuleName(value);
      }
      roomConfig[deviceKey][property] = value;
      // WHAT IT WAS, AND WHAT IT IS NOW. A log line saying only the new value
      // answers "what does this say" — which the config already answers — and
      // not "what changed", which is the question somebody has six months
      // later. Coalesced, because this fires per keystroke.
      if (previous?.toString() != value?.toString()) {
        logRoomEdit(
          itemKey: 'device:$deviceKey',
          itemName: deviceKey,
          field: property,
          summary: _fieldChangeSummary(
            _beforeForRun('$deviceKey.$property', previous),
            value,
          ),
          coalesce: true,
        );
      }
      // Typing into a placeholder field is asking for the key back, whatever
      // was said about it earlier in the session.
      _omittedConfigKeys.remove('$deviceKey.$property');
      _forgetConversionOrigin(deviceKey, property);
      // A new python module was just selected: parse it right away (if it isn't
      // already cached) so its command/input dictionaries are ready instantly.
      if (property == 'module' && value is String && value.isNotEmpty) {
        getCommandsForModule(value);
        getInputsForModule(value);
      }
      // Moved onto a different connection style: load whatever the model's own
      // driver says that style wants (port, protocol, baud). Written BEFORE
      // the prune below, so a block that mentions a key the new connection has
      // no use for still gets tidied away by the one rule that does that.
      if (property == 'com_type' &&
          value is String &&
          previous?.toString() != value) {
        lastComTypeDefaults = applyComTypeDefaults(deviceKey);
      } else {
        lastComTypeDefaults = const [];
      }
      // Switching a device to a connection that can't use a property it still
      // carries (com_type Serial -> Network, leaving serial_port behind) drops
      // it now rather than leaving dead data in the file the editor no longer
      // shows. Only ever removes keys the schema's "hideWhen" rules out.
      _dropKeysHiddenByConnection(deviceKey);
      // Retyping the room's sources is the moment the input numbers behind
      // the ones it just lost stop meaning anything — see
      // [pruneUnusedSourceInputs]. Camera count is handled here too, for the
      // paths that write dev_cameras directly rather than through the wizard.
      if (deviceKey == 'SYSTEM_SETUP' &&
          (property == 'gui_tab_type' || property == 'dev_cameras')) {
        pruneUnusedSourceInputs();
      }
      notifyListeners();
    }
  }

  /// Removes the properties of [sectionKey] that the schema's "hideWhen" rules
  /// out for the block as it now stands — the serial_port and baud a device
  /// keeps hold of after being switched from Serial to Network. Returns the
  /// keys removed (empty in the ordinary case, which is every edit that isn't
  /// a com_type change). Never notifies: the callers already do.
  List<String> _dropKeysHiddenByConnection(String sectionKey) {
    final section = roomConfig[sectionKey];
    if (section is! Map) return const [];
    final block = section.map((k, v) => MapEntry(k.toString(), v));
    final stale = uiSchema.staleKeysIn(sectionKey, block);
    for (final key in stale) {
      final removed = section.remove(key);
      _forgetConversionOrigin(sectionKey, key);
      AppLogger.logInfo(
          "Removed '$sectionKey.$key' (${jsonEncode(removed)}): not valid for a "
          "${section['com_type'] ?? 'this'} connection.");
    }
    return stale;
  }

  /// `SECTION.key` for every property the user has deleted on a tab.
  ///
  /// The schema offers some keys BEFORE they exist in a block — "addIfMissing"
  /// on device_id, service_port, use_device_mute, the keep-alive fields, baud
  /// — so a device converted to something that doesn't use them still has
  /// somewhere to type one in. That placeholder is also what made those keys
  /// look undeletable: the trash button took the key out of the config and the
  /// missing-field pass put the field straight back, so the delete appeared to
  /// do nothing. Recording the deletion is what makes it stick.
  ///
  /// Session-only, like [_prunedSystemKeys]: it is a note about what the user
  /// has said no to in this sitting, not a property of the room. Typing a
  /// value in, or adding the key back through Check Defaults, clears it.
  final Set<String> _omittedConfigKeys = {};

  /// True when the user deleted [property] from [sectionKey] and the schema
  /// should stop offering it back as a placeholder field.
  bool isConfigKeyOmitted(String sectionKey, String property) =>
      _omittedConfigKeys.contains('$sectionKey.$property');

  /// Removes one property from a section (device block or SYSTEM_SETUP).
  /// The delete buttons on the Devices/System tabs land here; the key can be
  /// re-added later via the Check Defaults dialog.
  ///
  /// Also records the deletion so a schema placeholder does not put the field
  /// straight back — see [_omittedConfigKeys]. That is why this notifies even
  /// when the key was not in the config: the field on screen was an offer, and
  /// declining it has to change what is drawn.
  void removeConfigKey(String sectionKey, String property) {
    final section = roomConfig[sectionKey];
    if (section is! Map) return;
    _omittedConfigKeys.add('$sectionKey.$property');
    if (section.containsKey(property)) {
      section.remove(property);
      // Otherwise the entry outlives the key and Check Defaults re-adding it
      // later would bring the old conversion color back with it.
      _forgetConversionOrigin(sectionKey, property);
    }
    notifyListeners();
  }

  /// Adds one property to a section (the Check Defaults dialog's "+ Add").
  /// Existing values are never overwritten.
  void addConfigKey(String sectionKey, String property, dynamic value) {
    final section = roomConfig[sectionKey];
    if (section is Map && !section.containsKey(property)) {
      // Asking for it back is the opposite of having deleted it.
      _omittedConfigKeys.remove('$sectionKey.$property');
      section[property] = value;
      notifyListeners();
    }
  }

  /// Properties the current [sectionKey] block is missing compared to its
  /// defaults, mapped to the default value that would be added. Sources:
  ///   1. the template config's matching block — the exact section name, or
  ///      the family's `<PREFIX>1` block with the index substituted in
  ///   2. ui_schema.json "device_defaults" (devices) or "system_defaults"
  ///      (SYSTEM_SETUP), filling anything the template doesn't cover
  /// Returns {} when the section doesn't exist or nothing is missing.
  Future<Map<String, dynamic>> missingDefaultsFor(String sectionKey) async {
    final current = roomConfig[sectionKey];
    if (current is! Map) return {};

    final Map<String, dynamic> defaults = {};

    // 1. Template block
    try {
      final file = File(effectiveTemplateFilePath);
      if (await file.exists()) {
        final template = jsonDecode(await file.readAsString());
        if (template is Map) {
          dynamic block = template[sectionKey];
          if (block == null && sectionKey != 'SYSTEM_SETUP') {
            final family = uiSchema.deviceTypeForSection(sectionKey);
            if (family != null) block = template['${family.prefix}1'];
          }
          if (block is Map) {
            final copy = block.map((k, v) => MapEntry(k.toString(), v));
            defaults.addAll(sectionKey == 'SYSTEM_SETUP'
                ? copy
                : _indexSubstitute(copy, sectionKey));
          }
        }
      }
    } catch (e) {
      AppLogger.logError(
          'Check Defaults: could not read template $effectiveTemplateFilePath', e);
    }

    // 2. Schema defaults fill any gaps the template leaves
    final schemaDefaults = sectionKey == 'SYSTEM_SETUP'
        ? uiSchema.systemDefaults
        : (uiSchema.sectionDefaults[sectionKey] ??
            uiSchema.defaultsFor(sectionKey));
    schemaDefaults.forEach((k, v) => defaults.putIfAbsent(k, () => v));

    defaults.removeWhere((k, v) => current.containsKey(k));

    // Never offer back a key the device's module lists as unused for this
    // model — otherwise Check Defaults hands the scaler its group_* audio
    // settings again right after the conversion stripped them.
    final omits = moduleOmitsFor(current['module']?.toString() ?? '');
    if (omits.isNotEmpty) {
      defaults.removeWhere((k, v) => keyMatchesOmitPattern(k, omits));
    }

    // Same for a key the connection can't use: the template's PROJECTORDEVICE_1
    // is a Network device, so offering its serial_port to every projector would
    // put back exactly what the rest of this change takes out.
    final block = current.map((k, v) => MapEntry(k.toString(), v));
    defaults.removeWhere(
        (k, v) => uiSchema.isHiddenFor(k, block, sectionKey: sectionKey));
    return defaults;
  }

  /// Parses an Extron Python module file to extract valid keep-alive commands.
  Future<List<String>> getCommandsForModule(String moduleFileName) async {
    // Construct the full local path based on the app settings and the json module string
    final fullPath = modulePyPath(moduleFileName);

    if (_moduleCommandsCache.containsKey(fullPath)) {
      return _moduleCommandsCache[fullPath]!;
    }

    try {
      final file = File(fullPath);
      if (!await file.exists()) return [];
      
      final content = await file.readAsString();
      
      // Regex to find python methods that start with "Update"
      final updateMethodRegExp = RegExp(r"def\s+Update([A-Za-z0-9_]+)\s*\(");
      
      // USE A SET INSTEAD OF A LIST TO PREVENT DUPLICATES
      final Set<String> uniqueCommands = {};

      for (final match in updateMethodRegExp.allMatches(content)) {
        final cmd = match.group(1);
        if (cmd != null) {
          uniqueCommands.add(cmd); // Sets automatically ignore duplicates
        }
      }

      // Convert back to a list and sort alphabetically for a better UI experience
      final commands = uniqueCommands.toList()..sort();

      _moduleCommandsCache[fullPath] = commands;
      return commands;
    } catch (e, stack) {
      AppLogger.logError("Error parsing python module at $fullPath", e, stack);
      return [];
    }
  }

  /// Returns the valid STATES of one command in an Extron Python module, for
  /// the schema-driven "module_states" field type (e.g. ui_schema.json says a
  /// projector's 'input' options come from the module's 'Input' command).
  /// Looks, in order, at:
  ///   1. `self.Commands = { '<command>': { 'AllowedValues': [...] } }`
  ///   2. `def Set<command>:`   the KEYS of its ValueStateValues dict
  ///   3. `def __Match<command>:` the VALUES of its ValueStateValues dict
  ///   4. the `self.<dict>[value]` lookup inside `Set<command>` (per-model
  ///      like self.InputStateValues / self.set_input_states); the union of
  ///      every model's keys is returned
  /// Returns [] when the module file or the command can't be resolved, so the
  /// field falls back to free text entry.
  Future<List<String>> getStatesForModuleCommand(
      String moduleFileName, String command) async {
    if (moduleFileName.isEmpty || command.isEmpty) return [];
    final fullPath = modulePyPath(moduleFileName);
    final cacheKey = '$fullPath::$command';

    if (_moduleStatesCache.containsKey(cacheKey)) {
      return _moduleStatesCache[cacheKey]!;
    }

    try {
      final file = File(fullPath);
      if (!await file.exists()) return [];
      final content = await file.readAsString();
      final states = _parseCommandStates(content, command);
      _moduleStatesCache[cacheKey] = states;
      return states;
    } catch (e, stack) {
      AppLogger.logError(
          "Error parsing states for command '$command' in $fullPath", e, stack);
      return [];
    }
  }

  // ---------------------------------------------------------------------
  //  MODEL REGISTRY / DEVICE_INFO PARSING
  //  Each driver .py may declare, at module level (outside any class):
  //
  //    DEVICE_INFO = {
  //        "device_type": "dsp",
  //        "models": ["DMP 64 Plus C", "DMP 64 Plus C V"],
  //        "connection": {
  //            "com_type": "Network",
  //            "protocol": "TCP",
  //            "net_port": 22023
  //        },
  //        "defaults": {
  //            "keep_alive_command": "RefreshMatrix",
  //            "keep_alive_interval": 30
  //        },
  //        # Optional: what this driver wants on each connection style. Loaded
  //        # when com_type is changed in the editor, and merged over
  //        # "connection"/"defaults" when a model is picked. May also be
  //        # grouped under a "com_types" dict.
  //        "network": {"protocol": "TCP", "net_port": 22023},
  //        "serialoverethernet": {"protocol": "TCP", "net_port": 2001},
  //        "serial": {"baud": 38400, "host": "processor1"}
  //    }
  //
  //  "device_type" (string or list) restricts which device-family tabs
  //  offer these models: projector, display, camera, switcher, dsp, usb,
  //  power, mediaport, wireless, recorder, screen (matched against the
  //  ui_schema device_types families; omit it to show everywhere).
  //  "models" marks this file as the DEFAULT module for those models;
  //  "connection" and "defaults" keys are config.json device properties
  //  applied when a model is picked (two keys purely for readability).
  //  "network" / "serial" / "serialoverethernet" / "http" are the same
  //  thing per connection style — see [moduleComTypeDefaults] — and are
  //  what makes changing com_type in the editor load the right port.
  //  Files without DEVICE_INFO still contribute the keys of their
  //  self.Models dict so the dropdown is populated everywhere.
  // ---------------------------------------------------------------------

  /// Parses one module's model list + connection defaults into the registry.
  Future<void> _registerModuleModels(String moduleName) async {
    final fullPath = modulePyPath(moduleName);
    try {
      final file = File(fullPath);
      if (!await file.exists()) return;
      final content = await file.readAsString();

      List<String> models = [];
      List<String> deviceTypes = [];
      bool explicit = false;
      final info = parseDeviceInfo(fullPath, content);
      if (info != null) {
        final m = info['models'];
        if (m is List) {
          models = m.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
          explicit = models.isNotEmpty;
        }
        // "device_type": "projector"  or  ["projector", "display"]
        final dt = info['device_type'] ?? info['device_types'];
        if (dt is String && dt.trim().isNotEmpty) deviceTypes = [dt.trim()];
        if (dt is List) {
          deviceTypes = dt
              .map((e) => e.toString().trim())
              .where((s) => s.isNotEmpty)
              .toList();
        }
        // "connection" + "defaults" are both device properties to apply —
        // merged here; two keys in the file purely for readability.
        //
        // A None in a driver means "this model does not use the key", not
        // "write a null into the config". Every driver in the library spells
        // out `"device_id": None`, and taking that literally put a null
        // device_id on every device anybody picked a model for. Dropped here,
        // once, so the preview and the apply agree.
        final Map<String, dynamic> merged = {};
        for (final section in ['connection', 'defaults']) {
          final d = info[section];
          if (d is Map) {
            d.forEach((k, v) {
              if (v == null) return;
              merged[k.toString()] = v;
            });
          }
        }
        // Keyed by the stem so [moduleDefaultsFor] finds it from either the
        // bare name used here or the dotted spelling stored in a config.
        if (merged.isNotEmpty) moduleDefaults[moduleStem(moduleName)] = merged;

        // "network" / "serial" / "serialoverethernet" / "http": what this
        // driver wants when the device is reached THAT way. Read from the top
        // level of DEVICE_INFO, or from a "com_types" dict for an author who
        // would rather keep them together; the nested spelling wins, being the
        // more deliberate of the two. Nulls are dropped for the same reason
        // they are above — "this model does not use the key", not "write a
        // null". See [moduleComTypeDefaults].
        final byComType = <String, Map<String, dynamic>>{};
        void takeComTypeBlock(dynamic rawName, dynamic value) {
          if (value is! Map) return;
          final name = normalizeComTypeName(rawName.toString());
          if (!kComTypeDefaultNames.contains(name)) return;
          final props = <String, dynamic>{};
          value.forEach((k, v) {
            if (v == null) return;
            props[k.toString()] = v;
          });
          if (props.isNotEmpty) byComType[name] = props;
        }

        info.forEach(takeComTypeBlock);
        final nested = info['com_types'] ?? info['connections'];
        if (nested is Map) nested.forEach(takeComTypeBlock);
        if (byComType.isNotEmpty) {
          moduleComTypeDefaults[moduleStem(moduleName)] = byComType;
        }

        // "omit": key patterns this model does NOT use, even when a family
        // default supplies them (an IN1608 gets no group_* audio settings).
        final omit = info['omit'] ?? info['omit_keys'];
        if (omit is List) {
          final patterns = omit
              .map((e) => e.toString().trim())
              .where((s) => s.isNotEmpty)
              .toList();
          if (patterns.isNotEmpty) {
            moduleOmits[moduleStem(moduleName)] = patterns;
          }
        }
      }
      // Fallback: the driver's own self.Models dict keys
      if (models.isEmpty) models = parseSelfModels(content);

      // Remembered whether or not this module ends up owning them in the
      // registry — the name rewrite only needs to know which model names this
      // file's own defaults could be spelled with.
      if (models.isNotEmpty) moduleModels[moduleStem(moduleName)] = models;

      for (final model in models) {
        final existing = modelRegistry[model];
        // First module wins unless a later one declares the model EXPLICITLY
        // (DEVICE_INFO) and the current holder was only a fallback match.
        if (existing == null || (explicit && !existing.explicit)) {
          if (existing != null && existing.module != moduleName) {
            AppLogger.logInfo(
                "Model '$model': default module is now $moduleName (DEVICE_INFO) instead of ${existing.module}");
          }
          modelRegistry[model] = ModelEntry(
              model: model,
              module: moduleName,
              explicit: explicit,
              deviceTypes: deviceTypes);
        }
      }
    } catch (e, stack) {
      AppLogger.logError("Error parsing models from $fullPath", e, stack);
    }
  }

  /// Extracts the module-level DEVICE_INFO dict (column 0) as a JSON map.
  /// Tolerates Python syntax: single quotes, trailing commas, # comments,
  /// True/False/None. Returns null when absent or unparsable (logged).
  static Map<String, dynamic>? parseDeviceInfo(String fullPath, String content) {
    final m =
        RegExp(r'^DEVICE_INFO\s*=\s*\{', multiLine: true).firstMatch(content);
    if (m == null) return null;
    final block = _bracedBlockAt(content, m.end - 1);
    if (block == null) {
      AppLogger.logError("DEVICE_INFO in $fullPath never closes its braces");
      return null;
    }
    try {
      final decoded = jsonDecode(pythonLiteralToJson(block));
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (e) {
      AppLogger.logError(
          "DEVICE_INFO in $fullPath is not a valid dict - use JSON-style values (strings, numbers, lists, dicts)", e);
    }
    return null;
  }

  /// Converts a Python dict/list literal to JSON text: strips # comments,
  /// re-quotes single-quoted strings, maps True/False/None, drops trailing
  /// commas. String contents (either quote style) pass through untouched.
  static String pythonLiteralToJson(String src) {
    final out = StringBuffer();
    int i = 0;
    while (i < src.length) {
      final ch = src[i];
      if (ch == '#') {
        // Comment: skip to end of line (we are outside any string here)
        while (i < src.length && src[i] != '\n') {
          i++;
        }
        continue;
      }
      if (ch == "'" || ch == '"') {
        final quote = ch;
        i++;
        final buf = StringBuffer();
        while (i < src.length && src[i] != quote) {
          if (src[i] == '\\' && i + 1 < src.length) {
            buf.write(src[i]);
            buf.write(src[i + 1]);
            i += 2;
            continue;
          }
          buf.write(src[i]);
          i++;
        }
        i++; // closing quote
        var s = buf.toString();
        if (quote == "'") {
          // Python-escaped apostrophes become literal; bare " needs escaping
          s = s.replaceAll(r"\'", "'").replaceAll('"', r'\"');
        }
        out.write('"$s"');
        continue;
      }
      out.write(ch);
      i++;
    }
    var text = out.toString();
    text = text
        .replaceAll(RegExp(r'\bTrue\b'), 'true')
        .replaceAll(RegExp(r'\bFalse\b'), 'false')
        .replaceAll(RegExp(r'\bNone\b'), 'null');
    // Trailing commas before a closing } or ] are legal Python, not JSON
    text = text.replaceAllMapped(
        RegExp(r',(\s*[}\]])'), (match) => match.group(1)!);
    return text;
  }

  /// Keys of the driver's self.Models = {...} dict (fallback model source).
  static List<String> parseSelfModels(String content) {
    final m = RegExp(r'self\.Models\s*=\s*\{').firstMatch(content);
    if (m == null) return [];
    final block = _bracedBlockAt(content, m.end - 1);
    if (block == null) return [];
    return RegExp("['\"]([^'\"]+)['\"]\\s*:")
        .allMatches(block)
        .map((x) => x.group(1)!)
        .toSet()
        .toList();
  }

  /// Substitutes the device's trailing index into the index-bearing property
  /// values (btn_name, gve_id) of [map], mutating and returning it. e.g. for
  /// deviceKey CAMERADEVICE_3, a btn_name ending in "Cam1" becomes "Cam3".
  /// A trailing "_X" placeholder (the synthesized template, e.g.
  /// Btn_Con_PROJECTORDEVICE_X) becomes the index too. Values with neither
  /// (or an empty value) are left alone.
  ///
  /// A `{n}` anywhere in the value is also replaced, which is the only thing
  /// that works for a name whose number is in the MIDDLE — the share room's
  /// stations are `Btn_Station_1_Status`, so the trailing-digit rule above
  /// would have handed every station the same button.
  Map<String, dynamic> _indexSubstitute(
      Map<String, dynamic> map, String deviceKey) {
    final idxMatch = RegExp(r'(\d+)$').firstMatch(deviceKey);
    if (idxMatch == null) return map;
    final idx = idxMatch.group(1)!;
    // 'alias' is on this list because a button panel is addressed by it — it
    // is that family's btn_name, naming the device in the GC project, and a
    // second panel copied from the first with Button_Panel_1 still in it
    // silently drives the first one.
    //
    // 'relay_port' is here for the same reason and reads the same way:
    // projector <n>'s box power is on RLY<n>, so the template block's
    // "RLY1" has to become "RLY2" on the second projector or all four
    // blocks fire the first projector's relay. Only PROJECTORDEVICE
    // carries the key -- the screens name their three ports separately
    // (relay_port_up/_down/_stop, RLY1-3 then RLY4-6), and those must NOT
    // be re-indexed: screen 2's up is RLY4, not RLY2.
    for (final key in const ['btn_name', 'gve_id', 'alias', 'relay_port']) {
      final v = map[key];
      if (v != null && v.toString().isNotEmpty) {
        final raw = v.toString();
        map[key] = raw.contains('{n}')
            ? raw.replaceAll('{n}', idx)
            : raw
                .replaceFirst(RegExp(r'\d+$'), idx)
                // Only an X directly after an underscore is a placeholder — a
                // btn_name legitimately ending in X (e.g. "..._MTX") is kept.
                .replaceFirst(RegExp(r'(?<=_)X$'), idx);
      }
    }
    return map;
  }

  /// Rewrites the module's DEVICE_INFO defaults to name the model that was
  /// actually PICKED, mutating and returning [map].
  ///
  /// One driver usually covers a whole product line, but its "defaults" can
  /// only spell out one of them: the file serving both DTP CrossPoint 82 4K
  /// and 84 4K carries `"name": "Switcher - DTP CrossPoint 82 4K"`, so picking
  /// the 84 named the device an 82. Any default value containing one of the
  /// module's OWN declared model names (see [moduleModels]) has that name
  /// swapped for [model] — so the rule only ever fires on a value the module
  /// wrote a model into, and leaves generic values (btn_name, gve_id, the
  /// keep-alive) untouched.
  Map<String, dynamic> _modelSubstitute(
      Map<String, dynamic> map, String moduleValue, String model) {
    final declared = moduleModels[moduleStem(moduleValue)];
    if (declared == null || model.isEmpty) return map;

    // Longest first: "DTP CrossPoint 82 4K IPCP SA" must win over the
    // "DTP CrossPoint 82 4K" it starts with, or the suffix would be orphaned.
    final candidates = List<String>.from(declared)
      ..sort((a, b) => b.length.compareTo(a.length));

    map.forEach((key, value) {
      if (value is! String || value.isEmpty) return;
      for (final declaredModel in candidates) {
        if (declaredModel == model || !value.contains(declaredModel)) continue;
        map[key] = value.replaceAll(declaredModel, model);
        return; // one model name per value
      }
    });
    return map;
  }

  /// Treats null and '' as the same "empty" value so a blank module default
  /// (e.g. ip_address: "") doesn't read as different from an absent key.
  static bool _valuesEqual(dynamic a, dynamic b) {
    final na = (a == null || a == '') ? '' : a;
    final nb = (b == null || b == '') ? '' : b;
    return na == nb;
  }

  /// [resolved] with every property the schema's "hideWhen" rules out for the
  /// block the defaults would PRODUCE — the current device with the defaults
  /// laid over it, so a module that sets com_type "Network" takes its own
  /// serial_port out with it. Most driver DEVICE_INFO "connection" dicts list
  /// serial_port whatever the connection is; without this, picking a network
  /// model would hand the device back the key the rest of this change removes.
  Map<String, dynamic> _dropHiddenDefaults(
      String deviceKey, Map<String, dynamic> resolved) {
    final dev = roomConfig[deviceKey];
    final Map<String, dynamic> after = {
      if (dev is Map) ...dev.map((k, v) => MapEntry(k.toString(), v)),
      ...resolved,
    };
    resolved.removeWhere(
        (k, v) => uiSchema.isHiddenFor(k, after, sectionKey: deviceKey));
    return resolved;
  }

  /// Computes what selecting [model] on [deviceKey] would do, WITHOUT mutating
  /// the config. Feeds the Model-change dialog: whether the module changes, the
  /// module's DEVICE_INFO defaults resolved for this device (trailing index
  /// substituted; site-specific blanks kept), and the fields whose current
  /// value differs from those defaults.
  /// [comType] asks what the driver says about ONE connection style rather
  /// than about the one the module names — see [_mergedModuleDefaults].
  ModelChangePreview previewModelSelection(String deviceKey, String model,
      {String? comType}) {
    final dev = roomConfig[deviceKey];
    final entry = modelEntryFor(model);
    if (dev is! Map || entry == null) {
      return ModelChangePreview(
        known: entry != null,
        newModule: normalizeModuleName(entry?.module ?? ''),
        moduleChanged: false,
        resolvedDefaults: const {},
        diffs: const [],
      );
    }
    // Compare in the stored import form so a device already on this module
    // isn't reported as a switch just because the registry key is the stem.
    final moduleImport = normalizeModuleName(entry.module);
    final currentModule =
        normalizeModuleName(dev['module']?.toString() ?? '');
    // Flat defaults with the driver's own block for the connection they land
    // on laid over them — see [_mergedModuleDefaults].
    final raw = _mergedModuleDefaults(entry.module, deviceKey,
        comType: comType);
    final resolved = _dropHiddenDefaults(
        deviceKey,
        _modelSubstitute(
            _indexSubstitute(Map<String, dynamic>.from(raw), deviceKey),
            entry.module,
            model));
    final diffs = <FieldDiff>[];
    resolved.forEach((k, v) {
      if (!_valuesEqual(dev[k], v)) {
        diffs.add(FieldDiff(key: k, current: dev[k], moduleDefault: v));
      }
    });
    return ModelChangePreview(
      known: true,
      newModule: moduleImport,
      moduleChanged: currentModule != moduleImport,
      resolvedDefaults: resolved,
      diffs: diffs,
    );
  }

  /// "Apply module defaults" action (a new/reset device): sets 'model' +
  /// 'module' and writes every resolved DEVICE_INFO default onto the block,
  /// overwriting existing values. Returns the "key = value" strings applied
  /// (for the acknowledgement snackbar). An unknown model only saves the text.
  List<String> applyModuleDefaults(String deviceKey, String model) {
    final List<String> applied = [];
    final dev = roomConfig[deviceKey];
    if (dev is! Map) return applied;
    dev['model'] = model;
    // Picking a model is the user setting these values, so they lose the
    // conversion coloring the same way a typed value does.
    _forgetConversionOrigin(deviceKey, 'model');

    final entry = modelEntryFor(model);
    if (entry != null) {
      // The registry is keyed by the bare file stem; the config stores the
      // dotted import path.
      final String moduleImport = normalizeModuleName(entry.module);
      if (dev['module'] != moduleImport) {
        dev['module'] = moduleImport;
        _forgetConversionOrigin(deviceKey, 'module');
        applied.add('module = $moduleImport');
      }
      final raw = _mergedModuleDefaults(entry.module, deviceKey);
      if (raw.isNotEmpty) {
        // One driver serves a whole line, so its defaults name only one of
        // them — rewrite to the model actually picked.
        final resolved = _dropHiddenDefaults(
            deviceKey,
            _modelSubstitute(
                _indexSubstitute(Map<String, dynamic>.from(raw), deviceKey),
                entry.module,
                model));
        resolved.forEach((k, v) {
          dev[k] = v;
          _forgetConversionOrigin(deviceKey, k);
          applied.add('$k = $v');
        });
      }
      // Parse the newly selected module right away so the keep-alive /
      // input dropdowns are ready the moment the form rebuilds.
      getCommandsForModule(entry.module);
      getInputsForModule(entry.module);
      AppLogger.logInfo(
          "Model '$model' applied to $deviceKey with module defaults: ${applied.isEmpty ? 'no changes needed' : applied.join(', ')}");
    }
    // The new module may have moved the device onto a different connection,
    // leaving behind properties the old one used (a serial_port from before
    // the switch to a network model).
    for (final key in _dropKeysHiddenByConnection(deviceKey)) {
      applied.add('$key removed');
    }
    notifyListeners();
    return applied;
  }

  /// Writes the driver's defaults for the keys the user ticked in the
  /// post-conversion review — see [auditModelDefaults].
  ///
  /// A SUBSET rather than [applyModuleDefaults]'s all-or-nothing, because a
  /// converted room is not a new device: its addresses, its names and whatever
  /// the site did on purpose are already in the block, and the answer to "does
  /// this VIA GO speak SSH or TCP" must not drag the room's naming with it.
  ///
  /// Returns the "key = value" strings written, for the log and the snackbar.
  List<String> applyModelDefaultValues(
    String deviceKey,
    Map<String, dynamic> values,
  ) {
    final dev = roomConfig[deviceKey];
    if (dev is! Map || values.isEmpty) return const [];
    final applied = <String>[];
    values.forEach((key, value) {
      if (dev[key] == value) return;
      dev[key] = value;
      // Written by the user now, so it stops reading as a converted value.
      _forgetConversionOrigin(deviceKey, key);
      applied.add('$key = $value');
    });
    if (applied.isEmpty) return applied;
    // A driver that moved the device onto another connection leaves the old
    // one's properties behind — the same tidy-up picking a model does.
    for (final key in _dropKeysHiddenByConnection(deviceKey)) {
      applied.add('$key removed');
    }
    final module = dev['module']?.toString() ?? '';
    if (module.isNotEmpty) {
      getCommandsForModule(moduleStem(module));
      getInputsForModule(moduleStem(module));
    }
    AppLogger.logInfo(
        "Driver defaults applied to $deviceKey: ${applied.join(', ')}");
    systemLogs.add(
        "-> Applied driver defaults to '$deviceKey': ${applied.join(', ')}");
    notifyListeners();
    return applied;
  }

  /// What the last [updateDeviceValue] com_type change loaded, as "key = value"
  /// strings, so the field that made the change can say so. Empty for every
  /// other edit.
  ///
  /// A field rather than a return value because [updateDeviceValue] is the one
  /// write path every editor field shares, and widening its signature for the
  /// benefit of one dropdown would touch a hundred call sites to tell
  /// ninety-nine of them nothing.
  List<String> lastComTypeDefaults = const [];

  /// Loads the module's own defaults for the connection style [deviceKey] is
  /// NOW on — DEVICE_INFO's "network", "serial" or "serialoverethernet" block.
  ///
  /// Applied rather than offered, unlike the driver-defaults review. Changing
  /// com_type already rewrites the block on its own (the keys the new
  /// connection cannot use are removed outright), so leaving the port and baud
  /// of the connection it just left in place would be the inconsistent half of
  /// the same move. What it will not do is overwrite a site-specific value with
  /// a blank: an empty string in a driver means "this belongs to the room", the
  /// same rule the model-pick path follows.
  ///
  /// Returns the "key = value" strings written, for the log and the snackbar.
  List<String> applyComTypeDefaults(String deviceKey) {
    final dev = roomConfig[deviceKey];
    if (dev is! Map) return const [];
    final module = dev['module']?.toString() ?? '';
    final comType = dev['com_type']?.toString() ?? '';
    if (module.isEmpty || comType.isEmpty) return const [];
    final block = comTypeDefaultsFor(module, comType);
    if (block == null || block.isEmpty) return const [];

    // Resolved for this device the same way a model pick resolves defaults —
    // the trailing index substituted, the schema's hidden keys dropped — so a
    // connection block cannot reintroduce a key the connection rules out.
    final resolved = _dropHiddenDefaults(
        deviceKey, _indexSubstitute(Map<String, dynamic>.from(block), deviceKey));

    final applied = <String>[];
    resolved.forEach((key, value) {
      // 'com_type' itself is what the user just set; a block that repeats it
      // must not be able to bounce the device back.
      if (key == 'com_type') return;
      if (value == null || value.toString().isEmpty) return;
      if (dev[key] == value) return;
      dev[key] = value;
      _forgetConversionOrigin(deviceKey, key);
      applied.add('$key = $value');
    });
    if (applied.isEmpty) return const [];

    AppLogger.logInfo(
        "Loaded $module's $comType defaults onto $deviceKey: ${applied.join(', ')}");
    systemLogs.add(
        "-> Loaded $comType defaults from $module onto '$deviceKey': "
        "${applied.join(', ')}");
    return applied;
  }

  /// "Keep current settings" action (a conversion): sets 'model' + 'module'
  /// only, leaving every other device property untouched. An unknown model
  /// just saves the model text.
  void keepSettingsSwitchModule(String deviceKey, String model) {
    final dev = roomConfig[deviceKey];
    if (dev is! Map) return;
    dev['model'] = model;
    _forgetConversionOrigin(deviceKey, 'model');

    final entry = modelEntryFor(model);
    if (entry != null) {
      final String moduleImport = normalizeModuleName(entry.module);
      dev['module'] = moduleImport;
      _forgetConversionOrigin(deviceKey, 'module');
      // Parse the newly selected module right away so the keep-alive /
      // input dropdowns are ready the moment the form rebuilds.
      getCommandsForModule(entry.module);
      getInputsForModule(entry.module);
      AppLogger.logInfo(
          "Model '$model' set on $deviceKey (module $moduleImport); existing settings kept.");
    }
    notifyListeners();
  }

  /// [name] with a mention of [oldModel] rewritten to [newModel], or [name]
  /// unchanged when it does not mention it.
  ///
  /// People name a device after what it is: "Projector 1 - PowerLite L630U",
  /// "Rack DSP — DMP 128 Plus". Swap the product and that name is a lie that
  /// nothing else in the room contradicts — it goes on the schematic, on the
  /// pack list, on the touch panel, and it is the name somebody reads out on
  /// site while looking at a different box.
  ///
  /// Only the model part moves. "Projector 1 - " is what this room calls the
  /// position, and the position has not changed.
  ///
  /// Case-insensitive, because a name is typed by a person and the catalog
  /// string is not ('powerlite l630u' is the same box). Bounded on both sides
  /// by a non-alphanumeric character, so a model that is a PREFIX of the one
  /// in the name cannot eat half of it: swapping a device recorded as "L630"
  /// must not turn "L630U" into "PT-MZ682BU8U".
  ///
  /// The implementation lives in model_swap.dart so the headless project swap
  /// can use it too; this stays as the name every existing caller already
  /// knows. One rule, two doors.
  static String renamedForModel(String name, String oldModel, String newModel) =>
      swap.renamedForModel(name, oldModel, newModel);

  /// Rewrites [deviceKey]'s `name` when it names [oldModel], so the block is
  /// called after the product it now holds. Returns the new name, or '' when
  /// nothing was written.
  ///
  /// Called AFTER the model is set, deliberately: a module's own DEVICE_INFO
  /// default may have supplied a name of its own on the way past, and that
  /// name — already carrying the new model — has nothing left for this to
  /// match, so the driver's answer wins without either having to know about
  /// the other.
  String renameDeviceForModel(
    String deviceKey,
    String oldModel,
    String newModel,
  ) {
    final dev = roomConfig[deviceKey];
    if (dev is! Map) return '';
    final current = dev['name']?.toString() ?? '';
    final renamed = renamedForModel(current, oldModel, newModel);
    if (renamed == current) return '';
    dev['name'] = renamed;
    _forgetConversionOrigin(deviceKey, 'name');
    AppLogger.logInfo(
        "$deviceKey renamed '$current' -> '$renamed' with the model swap.");
    notifyListeners();
    return renamed;
  }

  /// Sets 'model' and CLEARS 'module': the device is now a product no python
  /// driver claims, and nothing in the room can drive it.
  ///
  /// Clearing rather than leaving the old value is the whole point. A block
  /// that says `model: Display 86` over `module: modules.device.display_65`
  /// reads as configured, and would be commissioned as a 65 — where an empty
  /// module reads as what it is: a decision nobody has made yet. It is also
  /// what puts the red banner on the Devices tab (see
  /// [deviceModelModuleFault]), and it stays there until somebody picks a
  /// module, which is the only thing that can actually resolve it.
  void setModelWithoutModule(String deviceKey, String model) {
    final dev = roomConfig[deviceKey];
    if (dev is! Map) return;
    dev['model'] = model;
    _forgetConversionOrigin(deviceKey, 'model');
    final had = dev['module']?.toString() ?? '';
    dev['module'] = '';
    _forgetConversionOrigin(deviceKey, 'module');
    AppLogger.logInfo(
        "Model '$model' set on $deviceKey; no python module claims it, so the "
        "module${had.isEmpty ? '' : " ('$had')"} was cleared.");
    notifyListeners();
  }

  /// Resolves the PDF manual for [moduleName]: `<module file name>.pdf` in the
  /// Documentation folder (App Config; default `<root>/documentation`). Returns
  /// the file path when it exists, otherwise a user-facing error message (never
  /// both). Pure lookup — used by both the in-app viewer and the external-open
  /// path so the resolution rules stay in one place.
  ({String? path, String? error}) locateModuleManual(String moduleName) {
    if (moduleName.isEmpty) {
      return (path: null, error: 'Select a python module (or model) first.');
    }
    final baseName = moduleName.split('.').last;
    final pdfPath = path.join(effectiveDocumentationPath, '$baseName.pdf');
    if (!File(pdfPath).existsSync()) {
      return (path: null, error: 'No manual found: $pdfPath');
    }
    return (path: pdfPath, error: null);
  }

  /// Opens the PDF manual for [moduleName] in the OS default PDF viewer (the
  /// in-app viewer's "Open externally" fallback). Returns null on success,
  /// else a user-facing error message.
  Future<String?> openModuleDocumentation(String moduleName) async {
    final located = locateModuleManual(moduleName);
    if (located.error != null) return located.error;
    return openInDesktop(located.path!);
  }

  /// Hands [target] (a file or a folder) to the OS to open with whatever is
  /// registered for it. Returns null on success, else a user-facing message.
  Future<String?> openInDesktop(String target) async {
    if (target.isEmpty) return 'Nothing to open.';
    if (!File(target).existsSync() && !Directory(target).existsSync()) {
      return 'No longer there: $target';
    }
    try {
      await Process.start(
          Platform.isWindows
              ? 'explorer.exe'
              : (Platform.isMacOS ? 'open' : 'xdg-open'),
          [target],
          mode: ProcessStartMode.detached);
      AppLogger.logInfo('Opened $target');
      return null;
    } catch (e, stack) {
      AppLogger.logError('Failed to open $target', e, stack);
      return 'Could not open $target';
    }
  }

  /// Opens the folder holding [filePath] with the file itself highlighted where
  /// the platform supports it (Explorer and Finder both do). Falls back to just
  /// opening the folder. Returns null on success, else a user-facing message.
  ///
  /// Explorer exits non-zero even when it worked, so the exit code is ignored —
  /// a launch failure surfaces as an exception instead.
  Future<String?> revealInFileManager(String filePath) async {
    if (filePath.isEmpty) return 'Nothing to show.';
    final folder = path.dirname(filePath);
    if (!File(filePath).existsSync()) {
      // The file moved or was never written — the folder is still useful.
      return Directory(folder).existsSync()
          ? openInDesktop(folder)
          : 'No longer there: $filePath';
    }
    try {
      if (Platform.isWindows) {
        // One argument, comma included: explorer parses "/select,<path>" as a
        // unit and ignores a space-separated path.
        await Process.start('explorer.exe', ['/select,$filePath'],
            mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', ['-R', filePath],
            mode: ProcessStartMode.detached);
      } else {
        // No portable "select the file" on Linux desktops — open the folder.
        return openInDesktop(folder);
      }
      AppLogger.logInfo('Revealed $filePath');
      return null;
    } catch (e, stack) {
      AppLogger.logError('Failed to reveal $filePath', e, stack);
      return 'Could not open $folder';
    }
  }

  /// Extracts the state list for [command] from a module's source text.
  static List<String> _parseCommandStates(String content, String command) {
    final escaped = RegExp.escape(command);

    // 1. self.Commands entry: '<command>': { ... 'AllowedValues': [...] ... }
    final entryMatch =
        RegExp("['\"]$escaped['\"]\\s*:\\s*\\{").firstMatch(content);
    if (entryMatch != null) {
      final block = _bracedBlockAt(content, entryMatch.end - 1);
      if (block != null) {
        final allowedMatch =
            RegExp("['\"]AllowedValues['\"]\\s*:\\s*\\[").firstMatch(block);
        if (allowedMatch != null) {
          final listEnd = block.indexOf(']', allowedMatch.end);
          if (listEnd != -1) {
            final listText = block.substring(allowedMatch.end, listEnd);
            final values = RegExp("['\"]([^'\"]+)['\"]")
                .allMatches(listText)
                .map((m) => m.group(1)!)
                .toList();
            if (values.isNotEmpty) return values;
          }
        }
      }
    }

    // 2. def Set<command>: keys of its ValueStateValues dict are the states
    final setStates = _valueStateValuesIn(content, 'Set$command', keys: true);
    if (setStates.isNotEmpty) return setStates;

    // 3. def __Match<command>: dict is inverted, so the VALUES are the states
    final matchStates =
        _valueStateValuesIn(content, '__Match$command', keys: false);
    if (matchStates.isNotEmpty) return matchStates;

    // 4. Set<command> may index a per-model dict, e.g.
    //    self.InputStateValues[value] / self.set_input_states[value].
    //    Find the attribute(s) it indexes, then union the keys of every
    //    assignment of that attribute in the file (one per supported model).
    final defMatch =
        RegExp('def\\s+Set$escaped\\s*\\(').firstMatch(content);
    if (defMatch != null) {
      final nextDef = content.indexOf(RegExp(r'\n\s*def\s'), defMatch.end);
      final body = content.substring(
          defMatch.end, nextDef == -1 ? content.length : nextDef);
      final attrs = RegExp(r'self\.([A-Za-z_][A-Za-z0-9_]*)\s*\[\s*value\s*\]')
          .allMatches(body)
          .map((m) => m.group(1)!)
          .toSet();
      final Set<String> union = <String>{};
      for (final attr in attrs) {
        for (final m in RegExp('self\\.${RegExp.escape(attr)}\\s*=\\s*\\{')
            .allMatches(content)) {
          final block = _bracedBlockAt(content, m.end - 1);
          if (block == null) continue;
          union.addAll(RegExp("['\"]([^'\"]+)['\"]\\s*:")
              .allMatches(block)
              .map((mm) => mm.group(1)!));
        }
      }
      if (union.isNotEmpty) return union.toList();
    }

    return [];
  }

  /// Finds `def [methodName](` and returns the entries of the first local
  /// `...StateValues = { ... }` dict inside it (usually named
  /// ValueStateValues, sometimes e.g. InputStateValues) — dict keys when
  /// [keys], else dict values. Returns [] when the method or dict is absent.
  static List<String> _valueStateValuesIn(String content, String methodName,
      {required bool keys}) {
    final defMatch =
        RegExp('def\\s+${RegExp.escape(methodName)}\\s*\\(').firstMatch(content);
    if (defMatch == null) return [];

    // Method body: up to the next 'def ' so we never read another method's dict
    final nextDef = content.indexOf(RegExp(r'\n\s*def\s'), defMatch.end);
    final body = content.substring(
        defMatch.end, nextDef == -1 ? content.length : nextDef);

    final dictMatch =
        RegExp(r'[A-Za-z_]*StateValues\s*=\s*\{').firstMatch(body);
    if (dictMatch == null) return [];
    final block = _bracedBlockAt(body, dictMatch.end - 1);
    if (block == null) return [];

    // Entries look like 'Name' : 'code' — capture left or right side
    final pattern = keys
        ? RegExp("['\"]([^'\"]+)['\"]\\s*:")
        : RegExp(":\\s*['\"]([^'\"]+)['\"]");
    return pattern.allMatches(block).map((m) => m.group(1)!).toList();
  }

  /// Returns the text of the balanced {...} block whose opening brace is at
  /// [openIndex] in [text] (braces inside quotes are rare in these dicts and
  /// treated as structural). Null when the block never closes.
  static String? _bracedBlockAt(String text, int openIndex) {
    int depth = 0;
    for (int i = openIndex; i < text.length; i++) {
      final ch = text[i];
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) return text.substring(openIndex, i + 1);
      }
    }
    return null;
  }

  /// Attempts to parse raw string JSON and update the global state.
  /// Used by the raw JSON editor view.
  void updateConfigFromRawJson(String rawJson) {
    try {
      final parsed = jsonDecode(rawJson) as Map<String, dynamic>;

      // JSON "\r" escapes decode into REAL control characters — normalize
      // them to the literal two-character \r the processor GUI expects, so
      // preset names etc. stay correct even when edited via the raw editor
      // (the key mapper only covers the file/SFTP load path).
      final fixed = _normalizeCarriageReturnsIn(parsed);
      if (fixed > 0) {
        AppLogger.logInfo(
            "Normalized carriage returns in $fixed value(s) from raw JSON editor.");
      }

      roomConfig = parsed;
      _bumpConfigRevision(); // Hand-edited JSON: rebuild the form fields from it
      _preloadModulesFromConfig(); // Warm the parser caches for referenced modules
      notifyListeners();
      AppLogger.logInfo("Room configuration updated from raw JSON editor.");
    } catch (e, stack) {
      AppLogger.logError("Failed to parse raw JSON from editor", e, stack);
      rethrow; // Pass error to UI for user feedback
    }
  }

  /// Replaces REAL carriage-return control characters (\r\n or \r) in every
  /// string value of [cfg] with the two-character backslash+r sequence used
  /// by the processor GUI. When the config is saved, the JSON encoder escapes
  /// the backslash, so the file ON DISK contains \\r (e.g. gui_preset_name
  /// `Whiteboard<CR>Left` -> "Whiteboard\\rLeft" in config.json). Lone \n is
  /// left untouched. Returns how many values were changed. Mirrors the key
  /// mapper's escape_carriage_returns step so EVERY write path produces the
  /// same on-disk representation.
  int _normalizeCarriageReturnsIn(Map<String, dynamic> cfg) {
    int changed = 0;
    cfg.forEach((sectionName, block) {
      if (block is! Map) return;
      final Map<String, dynamic> section = block as Map<String, dynamic>;
      for (final key in section.keys.toList()) {
        final v = section[key];
        if (v is String && v.contains('\r')) {
          section[key] = v.replaceAll('\r\n', r'\r').replaceAll('\r', r'\r');
          changed++;
        }
      }
    });
    return changed;
  }

  /// Where the pre-save backup of the working file lives: `<name>_previous.json`
  /// beside it, the same sidecar convention
  /// `<name>_control_schematic.json` follows.
  /// '' when the session has no working file yet.
  String get saveBackupPath {
    if (currentConfigPath.isEmpty) return '';
    final dir = path.dirname(currentConfigPath);
    final base = path.basenameWithoutExtension(currentConfigPath);
    return path.join(dir, '${base}_previous.json');
  }

  /// The backup this session's last save actually wrote, so Undo can never
  /// offer a stale file: a backup left beside a DIFFERENT config (the path
  /// moved on) or one whose write failed is not something to restore from.
  String _lastSaveBackupPath = '';

  /// True when the last save's backup is still the one belonging to the
  /// working file — what enables the Undo button. Says nothing about whether
  /// the two files actually differ; [undoDeltas] answers that.
  bool get canUndoLastSave =>
      _lastSaveBackupPath.isNotEmpty &&
      _lastSaveBackupPath == saveBackupPath &&
      File(_lastSaveBackupPath).existsSync();

  /// Copies the working file to `<name>_previous.json` before it is
  /// overwritten. Best-effort: a backup that cannot be written (read-only
  /// folder, file in use) must not stop the save, but it does clear the undo
  /// marker — restoring an older backup would undo more than the user did.
  Future<void> _backupWorkingFile() async {
    _lastSaveBackupPath = '';
    final target = saveBackupPath;
    if (target.isEmpty) return;
    try {
      final source = File(currentConfigPath);
      // First save of a brand new file: nothing on disk to preserve yet.
      if (!await source.exists()) return;
      await source.copy(target);
      _lastSaveBackupPath = target;
      AppLogger.logInfo('Backed up $currentConfigPath to $target');
    } catch (e, stack) {
      AppLogger.logError('Failed to back up $currentConfigPath to $target', e, stack);
    }
  }

  /// Writes the CURRENT in-memory config to the active working file (the file
  /// opened locally, or the working copy chosen during an SFTP download),
  /// after copying what is on disk to `<name>_previous.json` so the save can
  /// be undone. Saves the FULL un-pruned config so no device blocks are ever
  /// lost on disk — export and SFTP upload still produce the pruned version.
  /// Returns the path written, or null when no working file is associated
  /// with this session (e.g. 'Create New' that hasn't been exported yet).
  /// Set by the Raw JSON tab while it is open: applies text typed there that
  /// hasn't reached the config yet. A save calls it first, so pressing Save
  /// straight after typing writes what is on screen rather than the config as
  /// it stood a few hundred milliseconds ago. Null whenever that tab is not
  /// mounted; a no-op when the editor has nothing pending.
  void Function()? pendingRawEditorCommit;

  Future<String?> saveCurrentConfigToFile() async {
    // Whatever is half-typed in the raw editor belongs in the config before
    // the config goes to disk.
    pendingRawEditorCommit?.call();
    if (currentConfigPath.isEmpty) return null;
    await _backupWorkingFile();
    try {
      const encoder = JsonEncoder.withIndent('    ');
      await File(currentConfigPath)
          .writeAsString(encoder.convert(_sortJson(roomConfig)));
      AppLogger.logInfo("Saved current config to working file $currentConfigPath");
      // Saving the project saves the WHOLE project: the AV diagram and its
      // cost estimate, and the control schematic, both of which live in
      // sidecars beside this file. Leaving them to their own buttons meant a
      // careful save could still lose an afternoon of pricing.
      final sidecars = await saveProjectSidecars();
      // ON THE JOB'S HISTORY, not only in the app log. "Who saved this room,
      // and when" is asked months later by somebody who was not here, and the
      // app log is a developer's file on one machine.
      _logRoomSaved(currentConfigPath, sidecars);
      // The room now matches its files, so the unsaved-work check — the dot on
      // the Save button, the prompt when a room is switched, and the warning
      // when the app is closed — has a fresh baseline. Without this the
      // toolbar's own Save left the room reporting itself as behind its file
      // for the rest of the session.
      markRoomSaved();
      // The work is in its file, so the recovery copy is a copy of nothing —
      // and a copy of nothing is what would be offered back on the next open.
      clearRoomRecovery();
      // The project's cached read of THIS room is now the stale one. Only
      // this one: dropping the whole cache made saving a room in a forty-room
      // job re-read forty files to learn that one of them had changed.
      _forgetCachedRoom(currentConfigPath);
      notifyListeners(); // The Undo button becomes available
      return currentConfigPath;
    } catch (e, stack) {
      AppLogger.logError("Failed to save working file $currentConfigPath", e, stack);
      rethrow; // Surface to the UI so the user knows the save failed
    }
  }

  /// What Undo would change: the working config as it stands now against the
  /// backup taken before the last save. Empty when there is no usable backup
  /// or the two already agree — which is what makes Undo a no-op the UI can
  /// say so about instead of silently rewriting an identical file.
  Future<List<ConfigDelta>> undoDeltas() async {
    if (!canUndoLastSave) return const [];
    try {
      final backup = jsonDecode(await File(_lastSaveBackupPath).readAsString());
      if (backup is! Map) return const [];
      return diffConfigs(
          backup.map((k, v) => MapEntry(k.toString(), v)), roomConfig);
    } catch (e, stack) {
      AppLogger.logError('Could not read backup $_lastSaveBackupPath', e, stack);
      return const [];
    }
  }

  /// Restores the pre-save backup: the working file is rewritten with it and
  /// the config is reloaded from it, so disk and screen agree again. One level
  /// deep by design — the marker is cleared afterwards, so Undo grays out
  /// rather than turning into a redo that ping-pongs between two states.
  /// Returns false when there is no usable backup.
  Future<bool> undoLastSave() async {
    if (!canUndoLastSave) return false;
    try {
      final contents = await File(_lastSaveBackupPath).readAsString();
      final parsed = jsonDecode(contents);
      if (parsed is! Map) return false;

      await File(currentConfigPath).writeAsString(contents);
      roomConfig = jsonDecode(contents);
      // The colors and the rejectable change list describe the load this
      // undo just stepped back from, so they no longer describe anything.
      _clearConversionProvenance();
      _bumpConfigRevision(); // Every tab now shows the restored value
      _preloadModulesFromConfig();
      AppLogger.logInfo(
          'Undid the last save: restored $currentConfigPath from $_lastSaveBackupPath');
      _lastSaveBackupPath = '';
      notifyListeners();
      return true;
    } catch (e, stack) {
      AppLogger.logError(
          'Failed to restore $currentConfigPath from $_lastSaveBackupPath', e, stack);
      return false;
    }
  }

  /// Every difference between two configs, one line per property. Sections are
  /// compared block by block and root scalars (`startup_watchdog_stage`) under
  /// an empty key, like the conversion diff does. Values are compared as JSON
  /// text so 0 and "0" read as the change they are.
  @visibleForTesting
  static List<ConfigDelta> diffConfigs(
      Map<String, dynamic> before, Map<String, dynamic> after) {
    final List<ConfigDelta> deltas = [];

    void compare(String section, Map beforeBlock, Map afterBlock) {
      for (final rawKey in afterBlock.keys) {
        final key = rawKey.toString();
        if (!beforeBlock.containsKey(key)) {
          deltas.add(ConfigDelta(
              section: section, key: key, kind: DeltaKind.added,
              after: afterBlock[key]));
        } else if (jsonEncode(beforeBlock[key]) != jsonEncode(afterBlock[key])) {
          deltas.add(ConfigDelta(
              section: section, key: key, kind: DeltaKind.changed,
              before: beforeBlock[key], after: afterBlock[key]));
        }
      }
      for (final rawKey in beforeBlock.keys) {
        final key = rawKey.toString();
        if (afterBlock.containsKey(key)) continue;
        deltas.add(ConfigDelta(
            section: section, key: key, kind: DeltaKind.removed,
            before: beforeBlock[key]));
      }
    }

    after.forEach((section, block) {
      final other = before[section];
      if (block is Map && other is Map) {
        compare(section, other, block);
      } else if (!before.containsKey(section)) {
        deltas.add(ConfigDelta(
            section: section, key: '', kind: DeltaKind.added, after: block));
      } else if (jsonEncode(other) != jsonEncode(block)) {
        deltas.add(ConfigDelta(
            section: section, key: '', kind: DeltaKind.changed,
            before: other, after: block));
      }
    });

    before.forEach((section, block) {
      if (after.containsKey(section)) return;
      deltas.add(ConfigDelta(
          section: section, key: '', kind: DeltaKind.removed, before: block));
    });

    deltas.sort((a, b) {
      final s = a.section.compareTo(b.section);
      return s != 0 ? s : a.key.compareTo(b.key);
    });
    return deltas;
  }

  /// Returns a formatted JSON string of the current config for the editor.
  /// Rendered PRUNED: devices beyond the dev_ counts (e.g. a family set to 0
  /// in the wizard) are hidden, so the raw view always matches what export
  /// and SFTP upload will actually write.
  String getPrettyConfigString() {
    if (roomConfig.isEmpty) return "{}";
    final encoder = const JsonEncoder.withIndent('    ');
    return encoder.convert(_sortJson(_pruneConfig(roomConfig)));
  }

  /// Helper to grab a default template for a device if the user increases the count.
  /// Priority: 1) the config's own `<PREFIX>1` block, 2) the family's "template"
  /// from ui_schema.json device_types, 3) a basic synthesized map.
  Map<String, dynamic> getDefaultDeviceBlock(String devicePrefix) {
    // Try to find an existing device of this type to use as a template (e.g. CAMERADEVICE_1)
    final templateKey = '${devicePrefix}1';
    if (roomConfig.containsKey(templateKey)) {
      return jsonDecode(jsonEncode(roomConfig[templateKey])); // Deep copy
    }

    // Schema-defined template for this family (device_types "template")
    final familyTemplate =
        uiSchema.deviceTypeForSection(templateKey)?.template;
    if (familyTemplate != null && familyTemplate.isNotEmpty) {
      return jsonDecode(jsonEncode(familyTemplate)); // Deep copy
    }

    // Synthesize a likely python module path based on the prefix (e.g. PROJECTORDEVICE_ -> modules.projectordevice)
    String cleanPrefix = devicePrefix.replaceAll('_', '').toLowerCase();
    
    // Fallback basic schema if no template is loaded
    return {
      "btn_name": "Btn_Con_${devicePrefix}X",
      "com_type": "Network",
      "host": "processor1",
      "gve_id": "${devicePrefix}X",
      "ip_address": "",
      "keep_alive_command": "",
      "keep_alive_interval": 30,
      "name": "New $devicePrefix",
      "module": "modules.$cleanPrefix", // <-- Triggers instant file loading
    };
  }

  /// Exports the pruned config.json using a user-prompted save dialog
  Future<bool> exportRoomConfig() async { // <-- UPDATED: Returns a bool for UI feedback
    pendingRawEditorCommit?.call(); // Raw-editor typing goes out with it
    if (roomConfig.isEmpty) {
      AppLogger.logError("Cannot export: Config is empty.");
      return false;
    }

    try {
      // Fetch details to generate a default file name
      final systemSetup = roomConfig['SYSTEM_SETUP'] ?? {};
      final gveBldg = systemSetup['gve_bldg'] ?? 'UNKNOWN_BLDG';
      final gveRoom = systemSetup['gve_room'] ?? 'UNKNOWN_ROOM';
      final defaultFileName = '${bldgAbbreviation(gveBldg.toString())}_${gveRoom}_config.json';

      // Prompt the user for a save location
      String? outputFile = await FilePicker.saveFile(
        dialogTitle: 'Save Room Configuration',
        fileName: defaultFileName,
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      // User canceled the picker
      if (outputFile == null) return false;
      // The dialog hands back exactly what was typed, so a name entered without
      // an extension would land as a file Windows can't associate with JSON.
      if (!outputFile.toLowerCase().endsWith('.json')) outputFile += '.json';

      final targetFile = File(outputFile);
      final encoder = const JsonEncoder.withIndent('    ');
      
      // Clean out unused devices and sort keys before saving
      Map<String, dynamic> exportData = _pruneConfig(roomConfig);

      await targetFile.writeAsString(encoder.convert(_sortJson(exportData)));
      AppLogger.logInfo("Config successfully saved to ${targetFile.path}");

      // The recovery copy belongs to the file this room is about to stop
      // being; retired before the path moves, or it would be orphaned under a
      // key nothing looks up any more.
      clearRoomRecovery();

      // ADOPT AS WORKING FILE: exporting ties the saved file to the session
      // (a wizard-built config starts with no path at all), so later saves —
      // and the Save Layout / Save AV Setup sidecars — have somewhere to live.
      // The synced-path markers move with it so the in-memory diagrams
      // survive instead of being reset as a "different config".
      currentConfigPath = outputFile;
      _schematicSyncedPath = outputFile;
      _avFlowSyncedPath = outputFile;
      // The diagrams and the cost estimate follow the config to its new home.
      await saveProjectSidecars();
      markRoomSaved();
      // The project's cached read of this room is now the stale one.
      _projectRooms.clear();
      notifyListeners();
      return true;

    } catch (e, stack) {
      AppLogger.logError("Failed to export room configuration", e, stack);
      return false;
    }
  }

  /// SYSTEM_SETUP keys taken out by [_pruneSystemKeysForCount], with the values
  /// they held. Setting the family's count back above zero puts them straight
  /// back, so changing your mind in the wizard doesn't cost you the outlet
  /// names (or a trip through Check Defaults). Session-only, and cleared
  /// whenever a different room is loaded.
  final Map<String, dynamic> _prunedSystemKeys = {};

  /// The family that owns [countKey], or null when the schema has no such
  /// entry.
  DeviceTypeSpec? _deviceTypeForCountKey(String countKey) {
    for (final t in uiSchema.deviceTypes) {
      if (t.countKey == countKey) return t;
    }
    return null;
  }

  /// Removes the SYSTEM_SETUP keys a device family owns (device_types
  /// "systemKeys") once its count is 0 — outlet names with no power controller
  /// behind them are dead data that still ships to the processor and still has
  /// to be read past on the System tab. Nothing happens for a family with no
  /// systemKeys, or while the count is above zero. Returns how many keys went,
  /// and logs them so the removal is never silent.
  int _pruneSystemKeysForCount(String countKey, int count) {
    if (count > 0) return 0;
    final spec = _deviceTypeForCountKey(countKey);
    if (spec == null || spec.systemKeys.isEmpty) return 0;

    final setup = roomConfig['SYSTEM_SETUP'];
    if (setup is! Map) return 0;
    final doomed = setup.keys
        .map((k) => k.toString())
        .where(spec.ownsSystemKey)
        .toList();
    if (doomed.isEmpty) return 0;

    for (final key in doomed) {
      _prunedSystemKeys[key] = setup[key]; // recoverable if the count returns
      setup.remove(key);
    }
    AppLogger.logInfo(
        "No ${spec.label.toLowerCase()} in this room: removed ${doomed.length} "
        "SYSTEM_SETUP key(s) that only configure them - ${doomed.join(', ')}");
    return doomed.length;
  }

  /// `input_*` keys taken out by [pruneUnusedSourceInputs], with the values
  /// they held, so retyping the sources back puts the switcher input numbers
  /// back with them. Session-only and cleared with the room, exactly like
  /// [_prunedSystemKeys].
  final Map<String, dynamic> _prunedSourceInputs = {};

  /// Removes the `input_*` keys this room's sources do not entitle it to, and
  /// restores any the sources have brought back.
  ///
  /// A room's source list is spelled in `gui_tab_type` ("DOC_USB_WL") and its
  /// camera count in `dev_cameras`; the switcher input each source lands on is
  /// a key of its own. Nothing tied the two together, so a room retyped from
  /// six sources down to four kept shipping `input_dvd` and `input_blu_ray` —
  /// input numbers for buttons the panel does not draw, pointing at switcher
  /// inputs something else is now plugged into. The rules live in
  /// ui_schema.json "source_inputs"; see [SourceInputRules].
  ///
  /// Returns how many keys went, and logs them, so the removal is never
  /// silent. Never notifies — every caller either notifies or is mid-load.
  int pruneUnusedSourceInputs() {
    final setup = roomConfig['SYSTEM_SETUP'];
    if (setup is! Map) return 0;
    final block = setup.map((k, v) => MapEntry(k.toString(), v));
    final rules = uiSchema.sourceInputs;

    // Put back first: a tab type that has just regained Wireless should get
    // its old input_wireless number back rather than a blank one, and doing
    // it before the removal keeps a single pass from fighting itself.
    final expected = rules.expectedKeys(
      tabType: block['gui_tab_type']?.toString() ?? '',
      cameraCount: int.tryParse(block['dev_cameras']?.toString() ?? '') ?? 0,
    );
    final restored = <String>[];
    for (final key in expected) {
      if (setup.containsKey(key)) continue;
      if (!_prunedSourceInputs.containsKey(key)) continue;
      setup[key] = _prunedSourceInputs.remove(key);
      restored.add(key);
    }
    if (restored.isNotEmpty) {
      AppLogger.logInfo(
          "Sources changed: restored ${restored.length} input key(s) this room "
          "has again - ${restored.join(', ')}");
    }

    final doomed = rules.staleKeysIn(block);
    if (doomed.isEmpty) return 0;
    for (final key in doomed) {
      _prunedSourceInputs[key] = setup[key]; // recoverable if the source returns
      setup.remove(key);
      _forgetConversionOrigin('SYSTEM_SETUP', key);
    }
    AppLogger.logInfo(
        "Sources are '${block['gui_tab_type'] ?? ''}' with "
        "${block['dev_cameras'] ?? '0'} camera(s): removed ${doomed.length} "
        "input key(s) the room has no source for - ${doomed.join(', ')}");
    return doomed.length;
  }

  /// The other half of [_pruneSystemKeysForCount]: giving a family hardware
  /// again restores the keys its own removal took, with their previous values.
  /// A key the config has since gained back on its own is never overwritten.
  int _restoreSystemKeysForCount(String countKey, int count) {
    if (count <= 0 || _prunedSystemKeys.isEmpty) return 0;
    final spec = _deviceTypeForCountKey(countKey);
    if (spec == null || spec.systemKeys.isEmpty) return 0;

    final setup = roomConfig['SYSTEM_SETUP'];
    if (setup is! Map) return 0;
    final restorable =
        _prunedSystemKeys.keys.where(spec.ownsSystemKey).toList();
    int restored = 0;
    for (final key in restorable) {
      final value = _prunedSystemKeys.remove(key);
      if (setup.containsKey(key)) continue; // the room already has its own
      setup[key] = value;
      restored++;
    }
    if (restored > 0) {
      AppLogger.logInfo(
          "${spec.label} back in this room: restored $restored SYSTEM_SETUP "
          "key(s) removed when the count was set to 0.");
    }
    return restored;
  }

  /// Updates the device count in SYSTEM_SETUP and generates/removes device blocks
  /// Finishes a device block that has just been dropped into [sectionKey]:
  /// the trailing-index substitutions, the schema's `device_defaults` for
  /// anything the block left out, the removal of keys this connection type
  /// can't use, and the keep-alive command off the module.
  ///
  /// Lifted out of [setDeviceCount] so the control-side prefill can create a
  /// block on exactly the same terms without going through the wizard's
  /// wipe-and-rebuild — which would discard the blocks it is adding to. Two
  /// routes to a device block that filled it in differently would be two
  /// kinds of room, and the difference would only show up at commissioning.
  void applyDeviceBlockDefaults(String sectionKey) {
    final device = roomConfig[sectionKey];
    if (device is! Map) return;
    final block = device is Map<String, dynamic>
        ? device
        : Map<String, dynamic>.from(device);

    _indexSubstitute(block, sectionKey);

    int added = 0;
    uiSchema.defaultsFor(sectionKey).forEach((prop, defaultValue) {
      if (block.containsKey(prop)) return;
      if (uiSchema.isHiddenFor(prop, block, sectionKey: sectionKey)) return;
      block[prop] = defaultValue;
      added++;
    });
    if (added > 0) {
      AppLogger.logInfo(
          'Applied $added schema default(s) from device_defaults to '
          '$sectionKey');
    }

    roomConfig[sectionKey] = block;
    _dropKeysHiddenByConnection(sectionKey);
    // ignore: unawaited_futures
    _applyKeepAliveDefaults([sectionKey]);
  }

  /// Moves the AV node at [oldId] onto [newId], bringing its cables and its
  /// rack placement with it.
  ///
  /// Used when a drawn device gains a config block: the two are one device,
  /// and leaving the node under its `AVNODE_7` id would keep it on every
  /// "on the diagram but not in the config" list forever. Returns false when
  /// there is no such node or the new id is already taken.
  bool rekeyAvNode(String oldId, String newId) {
    final index = avNodes.indexWhere((n) => n.id == oldId);
    if (index < 0 || oldId == newId) return false;
    if (avNodeById(newId) != null) return false;

    // fromConfig true: it mirrors a config block now, which is what makes it
    // vanish from the canvas if that block is later removed.
    avNodes[index] = avNodes[index].withId(newId).copyWith(fromConfig: true);

    for (int i = 0; i < avCables.length; i++) {
      final c = avCables[i];
      if (c.fromNodeId != oldId && c.toNodeId != oldId) continue;
      avCables[i] = AvCable(
        id: c.id,
        fromNodeId: c.fromNodeId == oldId ? newId : c.fromNodeId,
        fromPortId: c.fromPortId,
        toNodeId: c.toNodeId == oldId ? newId : c.toNodeId,
        toPortId: c.toPortId,
        signal: c.signal,
        label: c.label,
        waypoints: c.waypoints,
        colorOverride: c.colorOverride,
      );
    }

    final slot = avRackSlots.remove(oldId);
    if (slot != null) avRackSlots[newId] = slot;

    // A dismissal followed the old id; the device is in the config now, so
    // carrying it over would hide the very block that was just created.
    avDismissedDevices.remove(oldId);

    // Callouts pointing at the device follow it, or they become dangling
    // references on the floor plan.
    for (int p = 0; p < avFloorPlans.length; p++) {
      final plan = avFloorPlans[p];
      if (!plan.callouts.any(
        (c) => c.target == CalloutTarget.device && c.targetId == oldId,
      )) {
        continue;
      }
      avFloorPlans[p] = plan.copyWith(
        callouts: [
          for (final c in plan.callouts)
            if (c.target == CalloutTarget.device && c.targetId == oldId)
              c.copyWith(targetId: newId)
            else
              c,
        ],
      );
    }
    return true;
  }

  void setDeviceCount(String devKey, String devicePrefix, int count, Map<String, dynamic> defaultTemplateBlock) {
    if (!roomConfig.containsKey('SYSTEM_SETUP')) return;
    
    // Update the integer string in SYSTEM_SETUP (e.g., dev_cameras: "2")
    roomConfig['SYSTEM_SETUP'][devKey] = count.toString();

    // Setting a family to none also drops the SYSTEM_SETUP settings that only
    // exist to configure its hardware (the power controller's outlet names) —
    // see the schema's device_types "systemKeys". Raising the count again puts
    // them back, so the wizard's dropdown stays a reversible choice.
    _pruneSystemKeysForCount(devKey, count);
    _restoreSystemKeysForCount(devKey, count);

    // A room with no cameras has no camera inputs either, and a room that has
    // just gained one gets its old input numbers back — the same bargain, on
    // the keys the sources own rather than the ones a family owns.
    pruneUnusedSourceInputs();

    // 1. Remove existing devices of this type to ensure a clean slate
    roomConfig.removeWhere((key, value) => key.startsWith(devicePrefix));

    // 2. Generate new blocks based on the count
    final List<String> newKeys = [];
    for (int i = 1; i <= count; i++) {
      String newDeviceKey = '$devicePrefix$i';
      
      // Deep copy the template block so they don't share memory references
      Map<String, dynamic> newDevice = jsonDecode(jsonEncode(defaultTemplateBlock));
      
      // Update specific enumerations inside the newly created block.
      // Guarded so a schema-provided template missing one of these keys
      // (device_types "template") doesn't produce "null" strings.
      _indexSubstitute(newDevice, newDeviceKey); // btn_name, gve_id trailing index
      if (newDevice['name'] != null) {
        newDevice['name'] = '${newDevice['name'].toString().split('-').first.trim()} $i - Custom Model';
      }

      // SCHEMA DEFAULTS (ui_schema.json "device_defaults"): make sure this
      // device type's baseline properties exist — e.g. projectors always
      // get input/relay_host, DSPs their audio group numbers. Values from
      // the template block always win; only missing keys are added.
      int addedDefaults = 0;
      uiSchema.defaultsFor(newDeviceKey).forEach((prop, defaultValue) {
        if (newDevice.containsKey(prop)) return;
        // Skip anything this device's connection can't use ("hideWhen"), the
        // same rule the editor draws by — a new Network device is created
        // without a serial_port rather than given one to ignore.
        if (uiSchema.isHiddenFor(prop, newDevice, sectionKey: newDeviceKey)) {
          return;
        }
        newDevice[prop] = defaultValue;
        addedDefaults++;
      });
      if (addedDefaults > 0) {
        AppLogger.logInfo(
            "Applied $addedDefaults schema default(s) from device_defaults to $newDeviceKey");
      }

      roomConfig[newDeviceKey] = newDevice;
      // The block was copied from <PREFIX>1 (or a schema template), which may
      // have carried keys this device's connection can't use.
      _dropKeysHiddenByConnection(newDeviceKey);
      newKeys.add(newDeviceKey);
    }
    
    notifyListeners();

    // 3. Immediately verify each new device's module against the .py file in
    // the modules folder and load a valid keep-alive command from it.
    // ignore: unawaited_futures
    _applyKeepAliveDefaults(newKeys);
  }

  /// Takes device blocks out of the room config and closes the gap they leave.
  ///
  /// The inverse of the Cost tab's "add this line to the room config", and
  /// deliberately NOT [setDeviceCount]: that rebuilds a whole family from the
  /// template to reach a number, which would throw away the addresses and
  /// module choices on every OTHER device in the family to remove one of them.
  ///
  /// Three things have to happen together or the room is left inconsistent:
  ///
  ///   * the blocks go;
  ///   * what is left is RENUMBERED to run 1..N with no hole in it. Every
  ///     reader of a room walks the count and takes the sections that exist up
  ///     to it - see [activeDeviceKeysIn] - so a room left holding
  ///     PROJECTORDEVICE_1 and _3 reports one projector and hides the other
  ///     from the Devices tab, the schematic and the missing-module check;
  ///   * the family's count follows the blocks, so the Setup Wizard's dropdown
  ///     says what the room actually has.
  ///
  /// Any drawn box keyed onto a renumbered block moves with it, so the diagram
  /// and the config stay one device rather than two records of it.
  ///
  /// Returns the keys that actually went - a key naming no block is ignored
  /// rather than treated as an error, because the caller is usually working
  /// from a list that a previous removal may already have covered.
  List<String> removeDeviceBlocks(Iterable<String> sectionKeys) {
    final setup = roomConfig['SYSTEM_SETUP'];
    if (setup is! Map) return const [];

    final doomed = <String>{
      for (final key in sectionKeys)
        if (roomConfig[key] is Map) key,
    };
    if (doomed.isEmpty) return const [];

    // The families that have to be renumbered and recounted afterwards.
    final families = <DeviceTypeSpec>{};
    for (final key in doomed) {
      final spec = uiSchema.deviceTypeForSection(key);
      if (spec != null) families.add(spec);
    }

    for (final key in doomed) {
      roomConfig.remove(key);
    }

    // BEFORE the renumbering, not after. A device taken off the canvas by hand
    // is remembered by its section key so the next seed leaves it off; the
    // renumbering below is about to hand one of those keys to a DIFFERENT
    // device, which would make the survivor vanish from the diagram for a
    // reason nobody could see. A remembered key naming no block means nothing
    // anyway, so this is the moment it stops meaning anything.
    avDismissedDevices.removeWhere((id) => roomConfig[id] is! Map);

    for (final spec in families) {
      // What the family still holds, in its own numeric order - which is not
      // the map's order once a block has been removed and re-added.
      final survivors = <int, dynamic>{};
      for (final key in roomConfig.keys.toList()) {
        if (!key.startsWith(spec.prefix)) continue;
        final n = int.tryParse(key.substring(spec.prefix.length));
        if (n == null) continue;
        survivors[n] = roomConfig.remove(key);
      }
      final order = survivors.keys.toList()..sort();
      for (int i = 0; i < order.length; i++) {
        final from = '${spec.prefix}${order[i]}';
        final to = '${spec.prefix}${i + 1}';
        roomConfig[to] = survivors[order[i]];
        // Ascending, so a block only ever moves DOWN onto a number that has
        // already been vacated - the one order in which no rekey collides.
        if (from != to) rekeyAvNode(from, to);
      }

      // The count follows the blocks. Written in the wizard's own form - a
      // plain number - because that is what its dropdown reads back.
      setup[spec.countKey] = order.length.toString();
      // A family that has just emptied drops the SYSTEM_SETUP keys that only
      // configure its hardware, exactly as setting the wizard's count to none
      // does.
      _pruneSystemKeysForCount(spec.countKey, order.length);
    }

    // A room that has just lost its last camera has lost its camera input too.
    pruneUnusedSourceInputs();

    AppLogger.logInfo(
      'Removed ${doomed.length} device block(s): ${doomed.join(', ')}',
    );
    notifyListeners();
    return doomed.toList();
  }

  /// The keep-alive command [deviceKey] should poll on [moduleName], or '' when
  /// the module's .py can't be parsed. Only commands the module actually
  /// defines are ever returned. Sources, in order of authority:
  ///   1. the module's own DEVICE_INFO keep_alive_command — the driver author
  ///      naming the right poll for this hardware (an IN1608 polls
  ///      'Temperature', not the switcher family's 'RefreshMatrix')
  ///   2. the family's schema preference list (device_types
  ///      "keepAlivePreference"), in order
  ///   3. 'Power', then anything containing 'power' (the typical Extron poll),
  ///      else the module's first command
  Future<String> _resolveKeepAliveCommand(
      String deviceKey, String moduleName) async {
    final commands = await getCommandsForModule(moduleName);
    if (commands.isEmpty) return '';

    String pick(String wanted) => commands.firstWhere(
          (c) => c.toLowerCase() == wanted.toLowerCase(),
          orElse: () => '',
        );

    final fromModule =
        moduleDefaultsFor(moduleName)?['keep_alive_command']?.toString() ?? '';
    if (fromModule.isNotEmpty) {
      final match = pick(fromModule);
      if (match.isNotEmpty) return match;
    }

    final family = uiSchema.deviceTypeForSection(deviceKey);
    for (final pref in family?.keepAlivePreference ?? const <String>[]) {
      final match = pick(pref);
      if (match.isNotEmpty) return match;
    }

    return commands.firstWhere(
      (c) => c == 'Power',
      orElse: () => commands.firstWhere(
        (c) => c.toLowerCase().contains('power'),
        orElse: () => commands.first,
      ),
    );
  }

  /// For freshly added devices: parses the module's .py file (instant when
  /// preloaded) and ensures keep_alive_command is a command that actually
  /// exists in that module — see [_resolveKeepAliveCommand] for the order the
  /// default is chosen in.
  Future<void> _applyKeepAliveDefaults(List<String> deviceKeys) async {
    bool changed = false;
    for (final key in deviceKeys) {
      final device = roomConfig[key];
      if (device is! Map) continue;
      final moduleName = device['module']?.toString() ?? '';
      if (moduleName.isEmpty) continue;

      final commands = await getCommandsForModule(moduleName);
      if (commands.isEmpty) {
        // Module .py not found in the modules folder (or has no Update methods)
        AppLogger.logInfo("No matching .py commands for '$moduleName' on $key; keep-alive left as-is.");
        continue;
      }

      final current = device['keep_alive_command']?.toString() ?? '';
      if (current.isNotEmpty && commands.contains(current)) continue; // Already valid for this module

      final chosen = await _resolveKeepAliveCommand(key, moduleName);
      if (chosen.isEmpty) continue;
      device['keep_alive_command'] = chosen;
      changed = true;
      AppLogger.logInfo("Loaded keep_alive_command '$chosen' for $key from $moduleName.py");
    }
    if (changed) notifyListeners();
  }

  /// Load-time keep-alive audit, run after module resolution so every device
  /// has its .py to check against. A converted room inherits its keep-alive
  /// from the FAMILY default in key_map.json ('RefreshMatrix' for every
  /// switcher), which the specific model's module often doesn't implement — the
  /// device would then poll a command that doesn't exist. Any value the module
  /// doesn't define is replaced with the module's own default; values the
  /// module does define are left alone, so a deliberate site choice survives.
  /// Each change lands in systemLogs for the acknowledgement + change log.
  @visibleForTesting
  Future<void> validateKeepAliveCommands() async {
    for (final sectionKey in roomConfig.keys.toList()) {
      final device = roomConfig[sectionKey];
      if (device is! Map) continue;
      if (uiSchema.deviceTypeForSection(sectionKey) == null) continue;
      if (!device.containsKey('keep_alive_command')) continue;

      final moduleName = device['module']?.toString() ?? '';
      if (moduleName.isEmpty) continue; // already flagged by module resolution

      final commands = await getCommandsForModule(moduleName);
      if (commands.isEmpty) {
        systemLogs.add(
            "FLAGGED: '$sectionKey.keep_alive_command' could not be checked - "
            "no commands parsed from '$moduleName' (is the .py in the modules folder?).");
        continue;
      }

      final current = device['keep_alive_command']?.toString() ?? '';
      if (current.isNotEmpty && commands.contains(current)) continue;

      final chosen = await _resolveKeepAliveCommand(sectionKey, moduleName);
      if (chosen.isEmpty || chosen == current) continue;
      device['keep_alive_command'] = chosen;
      systemLogs.add(
          "MODULE: '$sectionKey.keep_alive_command' "
          "${current.isEmpty ? 'was empty' : "'$current' is not a command in '$moduleName'"} "
          "- set to '$chosen' from that module.");
    }
  }

  /// Config keys that are OPT-IN per room: the conversion must never turn them
  /// on, and anything that put them there gets undone. Section name -> the
  /// properties inside it.
  ///
  /// ENVIRONMENT.traceback_allowed is the case this exists for: it used to be
  /// injected as `true` into every converted room, which quietly switched full
  /// Python traceback reporting on for rooms nobody asked it for. The schema's
  /// section defaults no longer list that property, and this pass is the
  /// belt-and-braces half — whatever adds it (a stale ui_schema.json in the
  /// field, a template, a later schema edit), a room that didn't ask for it
  /// doesn't get it.
  ///
  /// The ENVIRONMENT block itself is NOT opt-in any more: the conversion adds
  /// it for controlscript_profile, which every room has to declare. Only the
  /// properties named here are stripped, so that injection survives.
  static const Map<String, List<String>> _optInProperties = {
    'ENVIRONMENT': ['traceback_allowed'],
  };

  /// Strips opt-in properties the loaded FILE did not carry, using the
  /// untouched parse in [_originalLoadedConfig] as the authority — so the test
  /// is "was this in the file the tech opened", not "is it in the config now".
  /// A room that really does set traceback_allowed keeps it (either value); the
  /// device report then states which way it is set.
  ///
  /// A section left empty by the strip is removed too, rather than exporting
  /// `"ENVIRONMENT": {}` to the processor. In practice the block now survives
  /// on its controlscript_profile — this only fires if that default is taken
  /// back out of the schema.
  ///
  /// [originalConfig] is the file as parsed; the load pipeline passes
  /// [_originalLoadedConfig].
  @visibleForTesting
  void removeUninvitedOptIns(Map<String, dynamic> originalConfig) {
    _optInProperties.forEach((sectionKey, properties) {
      final section = roomConfig[sectionKey];
      if (section is! Map) return;
      final original = originalConfig[sectionKey];
      final Map originalSection = original is Map ? original : const {};

      for (final key in properties) {
        if (!section.containsKey(key)) continue;
        if (originalSection.containsKey(key)) continue; // the file asked for it
        final removed = section.remove(key);
        systemLogs.add(
            "DEFAULTS: Removed '$sectionKey.$key' (was '$removed') - it is not "
            "in the loaded file and is opt-in per room, so the conversion "
            "leaves it off.");
      }

      if (section.isEmpty && !originalConfig.containsKey(sectionKey)) {
        roomConfig.remove(sectionKey);
        systemLogs.add(
            "DEFAULTS: Removed the now-empty '$sectionKey' section.");
      }
    });
  }

  /// `power<N>_outlet_<M>_action` in SYSTEM_SETUP, matched per outlet.
  static final RegExp _outletActionKey =
      RegExp(r'^(power\d+_outlet_\d+)_action$');

  /// Drops the outlet `_action` key, carrying a legacy 'Reboot' over to
  /// `_reboot_only` first so no outlet quietly stops cycling.
  ///
  /// An outlet's behavior used to be spread over two keys that said the same
  /// thing from different ends: `_action: "Reboot"` drove the panel button, and
  /// `_reboot_only` drove the remote reboot listener. The processor merged them
  /// onto `_reboot_only` — one key for both callers — which leaves `_action` as
  /// a third spelling of a setting that already has one, and a way for a room
  /// to contradict itself. Two toggles are the whole story now:
  /// `_supports_reboot` and `_reboot_only`.
  ///
  /// The precedence here is the processor's, so a room behaves the same after
  /// the strip as before it: a `_reboot_only` the LOADED FILE declared (true OR
  /// false) wins, and `_action` only decides the outlet when the file left
  /// `_reboot_only` absent or null. A null `_action` is the template's
  /// placeholder rather than a decision, so it is dropped without comment.
  ///
  /// The file has to be the authority rather than [roomConfig], because by the
  /// time this runs the companion_keys rule in key_map.json has already given
  /// every outlet a `_reboot_only: false`. Judging against the working config
  /// would read the conversion's own default as the room's decision and quietly
  /// turn a legacy reboot-only outlet into an ordinary one — the same trap
  /// [removeUninvitedOptIns] takes [_originalLoadedConfig] to avoid.
  ///
  /// [originalConfig] is the file as parsed; the load pipeline passes
  /// [_originalLoadedConfig].
  @visibleForTesting
  void foldOutletActionIntoRebootOnly(Map<String, dynamic> originalConfig) {
    final setup = roomConfig['SYSTEM_SETUP'];
    if (setup is! Map) return;
    final originalSetup = originalConfig['SYSTEM_SETUP'];
    final Map fileSetup = originalSetup is Map ? originalSetup : const {};

    for (final rawKey in setup.keys.map((k) => k.toString()).toList()) {
      final match = _outletActionKey.firstMatch(rawKey);
      if (match == null) continue;

      final outlet = match.group(1)!;
      final action = setup.remove(rawKey);
      final bool wantsReboot =
          action.toString().trim().toLowerCase() == 'reboot';
      if (!wantsReboot) continue; // null / "Off" / anything else said nothing

      final rebootOnlyKey = '${outlet}_reboot_only';
      final declared = fileSetup[rebootOnlyKey];
      if (declared != null) {
        // The room itself already ruled on this outlet; say so when the two
        // disagreed rather than changing behavior on the way past.
        if (declared != true) {
          systemLogs.add(
              "FLAGGED: '$rawKey' was 'Reboot' but the file also set "
              "'$rebootOnlyKey' to '$declared' - kept '$rebootOnlyKey', which "
              "is the key the processor reads. Removed '$rawKey'.");
        }
        continue;
      }

      setup[rebootOnlyKey] = true;
      systemLogs.add(
          "DEFAULTS: '$rawKey' was 'Reboot' - set '$rebootOnlyKey' to true and "
          "removed '$rawKey'. Reboot-only is one key now, read by both the "
          "panel button and the reboot listener.");
    }
  }

  /// Removes the config keys a device's module says its model doesn't use
  /// (DEVICE_INFO "omit"), run after module resolution so the module is known.
  ///
  /// This exists because the defaults that shape a device block are FAMILY
  /// -wide: key_map.json gives every SWITCHERDEVICE_* the seven `group_*` audio
  /// group numbers, and ui_schema.json does the same. That is right for a
  /// matrix acting as the room's audio hub and wrong for a plain scaler — an
  /// IN1608 ends up carrying audio group numbers nothing reads.
  ///
  /// Capability sniffing can't decide this: the IN1608 driver defines eight
  /// `UpdateGroup*` commands, so "does the module support groups" says yes for
  /// exactly the models that don't use them. Whether a model uses them is a
  /// deployment fact, so the module states it outright.
  ///
  /// Removals are logged (with the value) so they show in the acknowledgement
  /// and the change log rather than happening silently.
  @visibleForTesting
  void applyModuleOmissions() {
    for (final sectionKey in roomConfig.keys.toList()) {
      final device = roomConfig[sectionKey];
      if (device is! Map) continue;
      if (uiSchema.deviceTypeForSection(sectionKey) == null) continue;

      final moduleName = device['module']?.toString() ?? '';
      if (moduleName.isEmpty) continue;
      final patterns = moduleOmitsFor(moduleName);
      if (patterns.isEmpty) continue;

      for (final key in device.keys.map((k) => k.toString()).toList()) {
        // 'module' itself is what told us to do this — never strip it, and
        // leave the identity keys alone whatever a pattern says.
        if (key == 'module' || key == 'model') continue;
        if (!keyMatchesOmitPattern(key, patterns)) continue;
        final removed = device.remove(key);
        systemLogs.add(
            "DEFAULTS: Removed '$sectionKey.$key' (was '$removed') - "
            "'$moduleName' lists it as unused for this model.");
      }
    }
  }

  /// Load-time audit of every schema "module_states" field (today: a
  /// projector's `input`), run alongside the keep-alive check.
  ///
  /// These carry the same hazard: a converted room inherits the value from the
  /// FAMILY default in key_map.json — `input` = "HDBaseT" for every projector —
  /// and the specific model's module often doesn't implement that state, so the
  /// device would drive a port it doesn't have.
  ///
  /// Unlike the keep-alive, this only FLAGS. Which physical input the device is
  /// wired to is a site fact, not something the driver knows, so replacing it
  /// with the module's first state would be a guess that reads as a real
  /// setting. The tech gets the flag here, the red field on the device tab, and
  /// the choice: pick a state the module has, or add the missing one to it.
  @visibleForTesting
  Future<void> validateModuleStateFields() async {
    for (final sectionKey in roomConfig.keys.toList()) {
      final device = roomConfig[sectionKey];
      if (device is! Map) continue;
      if (uiSchema.deviceTypeForSection(sectionKey) == null) continue;

      final moduleName = device['module']?.toString() ?? '';
      if (moduleName.isEmpty) continue; // already flagged by module resolution

      for (final key in device.keys.map((k) => k.toString()).toList()) {
        final spec = uiSchema.specFor(key, sectionKey: sectionKey);
        if (spec?.type != 'module_states') continue;

        final current = device[key]?.toString() ?? '';
        if (current.isEmpty) continue;

        final command = spec!.moduleCommand ?? key;
        final states = await getStatesForModuleCommand(moduleName, command);
        // No states parsed at all: the module has no such command (or it can't
        // be read). That's a different problem from a wrong value, and the
        // field says so itself — don't cry wolf over every value here.
        if (states.isEmpty) continue;
        if (states.any((s) => s.toLowerCase() == current.toLowerCase())) {
          continue;
        }

        systemLogs.add(
            "FLAGGED: '$sectionKey.$key' is '$current', which is not a "
            "'$command' state in '$moduleName' - pick one of "
            "${states.join(', ')}, or add '$current' to the module.");
      }
    }
  }

  /// Internal helper to remove unused devices based on the `dev_` settings
  /// Logs a warning for every device family where MORE numbered blocks exist
  /// in the loaded config than the SYSTEM_SETUP dev_ count allows. This is
  /// informational only — counts are never changed automatically, because
  /// template files intentionally carry every possible block. It exists so a
  /// migrated legacy room (e.g. dev_projectors "1" with 4 projector blocks)
  /// doesn't silently lose blocks at export time.
  void _auditDeviceCounts() {
    final systemSetup = roomConfig['SYSTEM_SETUP'];
    if (systemSetup is! Map) return;

    // Families come from the UI schema's device_types (built-in list when
    // the file doesn't define any)
    final deviceMap = uiSchema.deviceCountMap;

    bool warned = false;
    deviceMap.forEach((countKey, prefix) {
      // Parse the configured count the same way pruning does
      final raw = systemSetup[countKey]?.toString().toLowerCase() ?? '';
      int count = raw == 'yes' ? 1 : (raw == 'no' ? 0 : (int.tryParse(raw) ?? 0));

      // Highest numbered block actually present in the config
      int highest = 0;
      for (final key in roomConfig.keys) {
        if (key.startsWith(prefix)) {
          final n = int.tryParse(key.substring(prefix.length)) ?? 0;
          if (n > highest) highest = n;
        }
      }

      if (highest > count) {
        systemLogs.add(
            "COUNT WARNING: $highest ${prefix}x blocks exist but $countKey is '$raw'. "
            "Blocks above $count are hidden in the tabs and PRUNED on export - "
            "raise the count in the Setup Wizard if this room really has them.");
        warned = true;
      }
    });
    if (warned) {
      systemLogs.add("--------------------------------------------------");
    }
  }

  /// Returns a copy of [node] with every object's keys sorted alphabetically
  /// (natural order, so PROJECTORDEVICE_2 sorts before PROJECTORDEVICE_10).
  /// Applied to every write/display path — the raw editor, Apply/save,
  /// Export, and SFTP upload — so config.json is always stored sorted.
  static dynamic _sortJson(dynamic node) {
    if (node is Map) {
      // EACH KEY IS SPLIT ONCE, NOT ONCE PER COMPARISON. Sorting asks the
      // comparator O(n log n) times, and the comparator used to tokenize both
      // of its arguments from scratch every time it was called — which put a
      // regex match, two lowercasings and four list allocations inside the
      // inner loop of a sort that runs over every nested object in the room.
      // Splitting up front and sorting the split keys is the same order by the
      // same rule (see [_compareNaturalParts]) for a twentieth of the work:
      // measured over a real config.json this went from 6.5ms to 0.3ms, and
      // it is on the path the toolbar's unsaved-changes dot takes.
      final split = [
        for (final k in node.keys)
          (key: k.toString(), parts: _naturalParts(k.toString())),
      ]..sort((a, b) => _compareNaturalParts(a.parts, b.parts));
      return <String, dynamic>{
        for (final e in split) e.key: _sortJson(node[e.key]),
      };
    }
    if (node is List) return node.map(_sortJson).toList();
    return node;
  }

  /// [s] lowercased and split into its maximal runs of digits and non-digits —
  /// exactly the tokens `RegExp(r'\d+|\D+')` used to produce, without the
  /// regex. 'projectordevice_10' -> ['projectordevice_', '10'].
  static List<String> _naturalParts(String s) {
    final lower = s.toLowerCase();
    final parts = <String>[];
    int i = 0;
    while (i < lower.length) {
      final bool digitRun = _isAsciiDigit(lower.codeUnitAt(i));
      int j = i + 1;
      while (j < lower.length && _isAsciiDigit(lower.codeUnitAt(j)) == digitRun) {
        j++;
      }
      parts.add(lower.substring(i, j));
      i = j;
    }
    return parts;
  }

  static bool _isAsciiDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

  /// Case-insensitive compare that treats digit runs as numbers, over keys
  /// already split by [_naturalParts]. A digit run that is too long to be an
  /// int falls back to a string compare, same as before — the rule has to hold
  /// for every key a config can carry, not just the ones that look like ours.
  static int _compareNaturalParts(List<String> a, List<String> b) {
    for (int i = 0; i < a.length && i < b.length; i++) {
      final an = int.tryParse(a[i]);
      final bn = int.tryParse(b[i]);
      final c = (an != null && bn != null)
          ? an.compareTo(bn)
          : a[i].compareTo(b[i]);
      if (c != 0) return c;
    }
    return a.length.compareTo(b.length);
  }

  Map<String, dynamic> _pruneConfig(Map<String, dynamic> configToPrune) {
    Map<String, dynamic> data = Map.from(configToPrune);

    // Families come from the UI schema's device_types (built-in list when
    // the file doesn't define any)
    final deviceMap = uiSchema.deviceCountMap;

    // FIX: the dev_ count keys live inside SYSTEM_SETUP, not at the config
    // root — the old root lookup meant pruning silently never happened.
    final systemSetup = data['SYSTEM_SETUP'];

    deviceMap.forEach((countKey, prefix) {
      // Prefer SYSTEM_SETUP, fall back to root for any legacy config layout
      dynamic countVal;
      if (systemSetup is Map && systemSetup.containsKey(countKey)) {
        countVal = systemSetup[countKey];
      } else if (data.containsKey(countKey)) {
        countVal = data[countKey];
      }

      if (countVal != null) {
        int count = 0;
        
        // Handle values like "Yes" in your dev_wireless setup
        if (countVal.toString().toLowerCase() == 'yes') {
          count = 1;
        } else {
          count = int.tryParse(countVal.toString()) ?? 0;
        }

        final keysToRemove = data.keys.where((k) {
          if (k.startsWith(prefix)) {
            int id = int.tryParse(k.replaceFirst(prefix, '')) ?? 999;
            return id > count; // Delete if the device ID exceeds the permitted count
          }
          return false;
        }).toList();
        for (var k in keysToRemove) {
          data.remove(k);
        }
      }
    });
    return data;
  }

  // ==========================================================================
  //  THE BUILDING PROJECT
  // ==========================================================================
  //  A job is usually a building, not a room. The project is a thin list of
  //  room config paths plus the vendor split (building_project.dart), and the
  //  rollup that prices it reads those rooms straight off disk
  //  (project_estimate.dart) rather than opening them.
  //
  //  That last point is the design, and it is why this section is so small.
  //  The project does not own rooms, cache their contents as its own state, or
  //  keep them in sync — the room the user has open is edited and saved by
  //  exactly the machinery it always was, and the project sees the change on
  //  the next re-price. There is one document open at a time, as before; the
  //  project is a lens over the folder, not a second editor.
  // ==========================================================================

  /// The open project. Never null — an app with no project open holds an empty
  /// one, so the Project tab has something to render and something to start
  /// typing into rather than a null check on every field.
  BuildingProject project = BuildingProject();

  /// Where it is saved, '' when it has never been saved.
  String currentProjectPath = '';

  /// Edited since the last save. The room's own dirty flag is separate and
  /// stays separate: saving a room must not silently save the project, and
  /// closing a project must not prompt about the room.
  bool projectDirty = false;

  /// Rooms as last read off disk, by room id.
  ///
  /// A cache, and only a cache. Re-pricing on every vendor edit — which is
  /// what makes tagging feel immediate — would otherwise re-read every room's
  /// four files on every keystroke. [refreshProjectRooms] drops it whenever
  /// the answer could have changed on disk.
  final Map<String, LoadedRoom> _projectRooms = {};

  /// The last answer [priceProject] gave, or null when it has to work it out.
  ///
  /// WHY MEMOISE AT ALL. Pricing a job is a pure function of the project, the
  /// rooms and the catalog, and it is not cheap: forty rooms of twenty-five
  /// devices is about a thousand priced lines, merged onto one master list and
  /// tagged. The Project tab asks for it on EVERY build — and the tab rebuilds
  /// on every keystroke in the project name box, every filter chip, every
  /// vendor pick — so the same thousand lines were being priced from scratch
  /// several times a second while somebody typed a job name.
  ///
  /// WHY IT CANNOT GO STALE. It is dropped in [notifyListeners], which every
  /// mutation on this provider goes through — so the cached answer can only
  /// survive a stretch in which nothing changed at all. That is the opposite
  /// of the usual invalidation problem: there is no list of inputs to keep in
  /// step with, and a new field added to the project next year invalidates
  /// this correctly without anybody remembering it exists.
  ProjectEstimate? _projectEstimate;

  /// Set for exactly one [notifyListeners], by a change that provably cannot
  /// alter a price. See [_projectChanged].
  bool _keepEstimate = false;

  /// True once this session actually has a JOB in front of it.
  ///
  /// Not the same question as "is the project object empty". A job started
  /// from New Project has no file and no rooms yet and is still the thing the
  /// user is working on; a session that has only ever opened one room has a
  /// perfectly valid empty project object and is NOT working on a job. The two
  /// are told apart by whether somebody asked for one - see [newProject],
  /// [openProject] and [closeProject].
  ///
  /// What it decides: whether the banner offers the way in to the Project tab
  /// at all. A button that led to an empty job list was the app's answer to
  /// "what am I working on" on a session where the answer was "one room".
  bool get hasOpenProject =>
      _projectStarted || currentProjectPath.isNotEmpty || project.rooms.isNotEmpty;

  bool _projectStarted = false;

  String get projectDisplayName {
    final name = project.name.trim();
    if (name.isNotEmpty) return name;
    if (currentProjectPath.isNotEmpty) {
      return path.basenameWithoutExtension(currentProjectPath);
    }
    return 'Untitled project';
  }

  /// Marks the project edited and tells the listeners.
  ///
  /// [repricing] is false for a change that CANNOT move a number on the
  /// estimate, and it is the only way the memoised estimate survives an edit.
  /// The default is true — a change is assumed to matter until somebody has
  /// looked at it and decided otherwise, because being slow is a nuisance and
  /// being wrong about a quote is not.
  ///
  /// What qualifies is narrower than it looks. The estimate holds the project
  /// itself by reference, so the job's own name, stakeholder and notes are
  /// already
  /// live in a cached answer — nothing is copied out of them. A room LABEL is
  /// not the same case: room refs are immutable and an edit replaces one, so a
  /// cached estimate would go on holding the old one. Neither is the currency,
  /// which every money figure on the estimate was formatted with.
  void _projectChanged({bool repricing = true}) {
    projectDirty = true;
    if (!repricing) _keepEstimate = true;
    notifyListeners();
  }

  // --- the file ------------------------------------------------------------

  /// Starts a new project, pre-loaded with the usual vendor split so the first
  /// room added is already tagged instead of landing in the untagged pile.
  void newProject({String name = '', String building = ''}) {
    project = BuildingProject(
      name: name,
      building: building,
      currency: currencySymbol,
    );
    project.vendors.addAll(starterVendors(project));
    currentProjectPath = '';
    projectDirty = false;
    _projectStarted = true;
    _projectRooms.clear();
    AppLogger.logInfo('New project started.');
    notifyListeners();
  }

  /// Opens a project file. Returns the error to show, or '' on success.
  Future<String> openProject(String file) async {
    try {
      project = await BuildingProject.load(file);
      currentProjectPath = file;
      projectDirty = false;
      _projectStarted = true;
      _projectRooms.clear();
      AppLogger.logInfo(
        'Project "${project.name}" opened from $file '
        '(${project.rooms.length} rooms, ${project.vendors.length} vendors).',
      );
      // Anything a crash left behind for THIS project, offered back the same
      // way a room's is.
      checkForProjectRecovery();
      notifyListeners();
      return '';
    } catch (e, stack) {
      AppLogger.logError('Failed to open the project $file', e, stack);
      return '$e';
    }
  }

  /// Puts the job away, leaving an empty one behind.
  ///
  /// EMPTY, not "a new project": [newProject] seeds the usual vendor split,
  /// which is right when somebody has asked to start a job and wrong when they
  /// have asked to stop working on one — a Close that left two vendors and an
  /// unsaved flag behind would be a Close that did not close anything.
  ///
  /// THE OPEN ROOM IS LEFT ALONE. A room is its own document: it was openable
  /// before the project existed and it stays open afterwards, exactly as it
  /// does when a different project is opened over the top of this one. Closing
  /// the job means the job, not everything on screen.
  ///
  /// Says nothing about unsaved work — that is the caller's to ask, before
  /// this is reached. See [closeProjectFile].
  void closeProject() {
    final was = projectDisplayName;
    project = BuildingProject(currency: currencySymbol);
    currentProjectPath = '';
    projectDirty = false;
    _projectStarted = false;
    _projectRooms.clear();
    AppLogger.logInfo('Project "$was" closed.');
    notifyListeners();
  }

  /// Writes the project. Returns the error to show, or '' on success.
  ///
  /// [to] re-homes it — and re-homing a project REWRITES ITS ROOM PATHS,
  /// because they are stored relative to wherever the file lives. Saving a
  /// project into a different folder without this would produce a file whose
  /// rooms all point at nothing.
  Future<String> saveProject({String to = ''}) async {
    final target = to.isNotEmpty ? to : currentProjectPath;
    if (target.isEmpty) return 'The project has no file to save to yet.';

    if (to.isNotEmpty && to != currentProjectPath) {
      // The campus pointer is stored relative to the project file too, so it
      // is re-homed with the rooms. A job saved into another folder without
      // this would keep a pointer that resolves somewhere it never was, and
      // Campus would open the wrong sheet or none.
      final campus = project.resolvedCampusFile(currentProjectPath);
      if (campus.isNotEmpty) {
        project.campusFile = BuildingProject.storeCampusPath(campus, to);
      }
      for (int i = 0; i < project.rooms.length; i++) {
        final room = project.rooms[i];
        final absolute = BuildingProject.resolvePath(
          room.configPath,
          currentProjectPath,
        );
        project.rooms[i] = room.copyWith(
          configPath: BuildingProject.storePath(absolute, to),
        );
      }
    }

    try {
      await project.save(target);
      currentProjectPath = target;
      projectDirty = false;
      clearProjectRecovery();
      AppLogger.logInfo('Project saved to $target.');
      notifyListeners();
      return '';
    } catch (e, stack) {
      AppLogger.logError('Failed to save the project to $target', e, stack);
      return '$e';
    }
  }

  // --- job details ---------------------------------------------------------

  void setProjectField({
    String? name,
    String? building,
    String? jobNumber,
    String? stakeholder,
    String? notes,
    String? currency,
  }) {
    if (name != null) project.name = name;
    if (building != null) project.building = building;
    if (jobNumber != null) project.jobNumber = jobNumber;
    if (stakeholder != null) project.stakeholder = stakeholder;
    if (notes != null && notes.trim() != project.notes.trim()) {
      project.notes = notes;
      _logProjectEdit(
        itemKey: 'project',
        itemName: project.name,
        field: 'Notes',
        summary: notes.trim().isEmpty ? 'cleared' : 'written',
        coalesce: true,
      );
    } else if (notes != null) {
      project.notes = notes;
    }
    if (currency != null && currency.isNotEmpty) project.currency = currency;
    // Typing a job name re-prices nothing. It used to re-price everything: the
    // Project tab asks for the estimate on every build, and this method is
    // called on every keystroke in four different boxes. The currency is the
    // one field here that money on the estimate was actually formatted with.
    _projectChanged(repricing: currency != null && currency.isNotEmpty);
  }

  /// Sets the share of what the job installs it means to hold spare.
  ///
  /// A FRACTION, clamped to nought..one. The box on the spares page types a
  /// percentage and divides; anything outside the range is a typo, and one
  /// honoured would put a recommendation of two hundred spare wall plates on
  /// the sheet.
  ///
  /// Re-prices, because every row of the cover table is worked out from it.
  void setSpareCoverTarget(double fraction) {
    final next = fraction.isNaN ? kSuggestedSpareCover : fraction.clamp(0.0, 1.0);
    if ((next - project.spareCoverTarget).abs() < 1e-9) return;
    project.spareCoverTarget = next;
    _logProjectEdit(
      itemKey: 'project',
      itemName: project.name,
      field: 'Recommended spare cover',
      summary: '${(next * 100).toStringAsFixed(next * 100 % 1 == 0 ? 0 : 1)}%',
      coalesce: true,
    );
    _projectChanged(repricing: true);
  }

  // --- rooms ---------------------------------------------------------------

  /// Adds a room config to the project. Returns the message to show — '' when
  /// it went in.
  ///
  /// A config already on the job is refused rather than added twice: a room
  /// listed twice doubles its cost in the building total and doubles every one
  /// of its parts on the master list, which is a wrong number that looks
  /// entirely plausible.
  String addRoomToProject(String configPath, {String label = ''}) {
    if (configPath.isEmpty) return 'No file chosen.';
    final absolute = path.normalize(configPath);
    if (!File(absolute).existsSync()) {
      return 'There is no file at $absolute.';
    }

    for (final existing in project.rooms) {
      final have = BuildingProject.resolvePath(
        existing.configPath,
        currentProjectPath,
      );
      if (path.equals(have, absolute)) {
        return '${path.basename(absolute)} is already on this project.';
      }
    }

    // The first room onto an UNTOUCHED project brings the usual vendor split
    // with it, so the master list is tagged the moment there is something on
    // it. Pressing New does this too; this covers the other way in — landing
    // on the tab and adding the open room — where a project with no vendors
    // would otherwise put every part in the untagged pile and make the
    // feature look broken.
    //
    // Only when there are no rooms AND no vendors: somebody who deleted the
    // starters on purpose is not offered them again on the next room.
    if (project.rooms.isEmpty && project.vendors.isEmpty) {
      project.vendors.addAll(starterVendors(project));
      AppLogger.logInfo(
        'Seeded the default vendor split on the first room of a new project.',
      );
    }

    final added = ProjectRoomRef(
      id: project.nextRoomId(),
      configPath: BuildingProject.storePath(absolute, currentProjectPath),
      label: label,
    );
    project.rooms.add(added);
    _logProjectEdit(
      itemKey: 'room:${added.id}',
      // Named by the code on the door rather than by the file stem — see
      // [projectRoomLogName]. The room has not been read yet at this point, so
      // this falls back to the stem until it has been.
      itemName: projectRoomLogName(added.id),
      field: 'Room',
      summary: 'added to the job',
    );
    AppLogger.logInfo('Room $absolute added to the project.');
    _projectChanged();
    return '';
  }

  /// Adds the room that is open right now — the common case, and the one that
  /// needs no file picker.
  String addCurrentRoomToProject() {
    if (currentConfigPath.isEmpty) {
      return 'Save the room first - a project points at files, so a room that '
          'has never been saved has nothing to point at.';
    }
    return addRoomToProject(currentConfigPath);
  }

  void removeRoomFromProject(String roomId) {
    // Read BEFORE the room leaves the job: the name is resolved off the
    // project, and a room that has already gone has no code to give.
    final was = projectRoomLogName(roomId);
    _logProjectEdit(
      itemKey: 'room:$roomId',
      itemName: was,
      field: 'Room',
      summary: 'removed from the job (its file is untouched)',
    );
    project.rooms.removeWhere((r) => r.id == roomId);
    // A spare bought FOR that room goes with it. A building spare does not -
    // it was never that room's, and it is still on the shelf list.
    project.dropSparesForRoom(roomId);
    _projectRooms.remove(roomId);
    _projectChanged();
  }

  void updateProjectRoom(
    String roomId, {
    String? label,
    bool? included,
    String? notes,
  }) {
    final index = project.rooms.indexWhere((r) => r.id == roomId);
    if (index < 0) return;
    final before = project.rooms[index];
    project.rooms[index] = before.copyWith(
      label: label,
      included: included,
      notes: notes,
    );

    // One line per DECISION. Typing a note is one decision however many
    // keystrokes it takes, so the note is logged as "written" rather than
    // once per character — and only when it actually changed.
    if (included != null && included != before.included) {
      _logProjectEdit(
        itemKey: 'room:$roomId',
        itemName: projectRoomLogName(roomId),
        field: 'Room',
        summary: included ? 'counted in the total' : 'taken out of the total',
      );
    }
    if (notes != null && notes.trim() != before.notes.trim()) {
      _logProjectEdit(
        itemKey: 'room:$roomId',
        itemName: projectRoomLogName(roomId),
        field: 'Notes',
        summary: notes.trim().isEmpty ? 'cleared' : 'written',
        coalesce: true,
      );
    }
    if (label != null && label.trim() != before.label.trim()) {
      _logProjectEdit(
        itemKey: 'room:$roomId',
        itemName: projectRoomLogName(roomId),
        field: 'Room',
        summary: label.trim().isEmpty ? 'label cleared' : 'renamed',
        coalesce: true,
      );
    }
    _projectChanged();
  }

  /// Moves a room up or down the list — the order the quote reads in.
  void moveProjectRoom(String roomId, int delta) {
    final from = project.rooms.indexWhere((r) => r.id == roomId);
    if (from < 0) return;
    final to = from + delta;
    if (to < 0 || to >= project.rooms.length) return;
    final room = project.rooms.removeAt(from);
    project.rooms.insert(to, room);
    _projectChanged();
  }

  // --- the rooms nobody has drawn ------------------------------------------
  //
  //  A job whose building has never been through this app still has a refresh
  //  plan to answer for, and the RYG imports are exactly that: thirty-four
  //  buildings of rooms with a date, a life and a figure, and not one config
  //  file between them. See [ManualRoom].
  //
  //  WHY THESE GO THROUGH THE PROVIDER AND NOT THROUGH THE DIALOG THAT LOADS
  //  OFF DISK. [showManualRoomsDialog] exists for the campus sheet, where no
  //  project is open and the only copy of the job is the one on disk. On the
  //  Project tab the job IS open, and editing a second copy read off disk
  //  would produce two versions of the same file - the one on screen and the
  //  one the dialog wrote - with whichever was saved last winning. So the open
  //  project is edited in memory, marked dirty, and written by the same Save
  //  the rest of the tab uses.

  /// Adds a room with no config to the open job. Returns the room.
  ManualRoom addProjectManualRoom({
    String name = '',
    DateTime? installedOn,
    int lifeYears = 0,
    double replacementCost = 0,
    String category = '',
    String notes = '',
  }) {
    final room = project.addManualRoom(
      name: name,
      installedOn: installedOn,
      lifeYears: lifeYears,
      replacementCost: replacementCost,
      category: category,
      notes: notes,
    );
    _logProjectEdit(
      itemKey: 'manual:${room.id}',
      itemName: room.name,
      field: 'Line item',
      summary: 'added to the plan',
    );
    _projectChanged();
    return room;
  }

  /// Writes a changed line item back onto the job - a date, a life, a figure.
  ///
  /// Logged by WHAT MOVED rather than as "edited", because those three fields
  /// are the whole of the room: a plan that shifted by four years and a plan
  /// that got eight thousand dearer are different events, and a history that
  /// called both of them "line item changed" would be a history nobody could
  /// read back.
  void updateProjectManualRoom(ManualRoom room) {
    final at = project.manualRooms.indexWhere((r) => r.id == room.id);
    if (at < 0) return;
    final before = project.manualRooms[at];
    project.updateManualRoom(room);

    void logged(String field, String summary) => _logProjectEdit(
      itemKey: 'manual:${room.id}',
      itemName: room.name,
      field: field,
      summary: summary,
    );

    if (before.name.trim() != room.name.trim()) {
      logged('Line item', 'renamed from ${before.name.trim()}');
    }
    if (before.installedOn != room.installedOn) {
      logged(
        'Last done',
        room.installedOn == null ? 'cleared' : formatIsoDate(room.installedOn!),
      );
    }
    if (before.lifeYears != room.lifeYears) {
      logged(
        'Years in service',
        room.lifeYears > 0 ? '${room.lifeYears} years' : 'the standard cycle',
      );
    }
    if ((before.replacementCost - room.replacementCost).abs() > 1e-9) {
      logged(
        'Cost to do again',
        room.replacementCost > 0
            ? '${project.currency}${room.replacementCost.toStringAsFixed(2)}'
            : 'off the base-cost card',
      );
    }
    if (before.category.trim() != room.category.trim()) {
      logged(
        'Priced from',
        room.category.trim().isEmpty ? 'the room line' : room.category.trim(),
      );
    }
    if (before.notes.trim() != room.notes.trim()) {
      logged('Notes', room.notes.trim().isEmpty ? 'cleared' : 'written');
    }
    _projectChanged();
  }

  /// Takes a line off the plan, and hands it BACK so the caller can offer an
  /// undo. Null when there was no such line.
  ///
  /// Returned rather than discarded because a line item is not a reference to
  /// anything: removing a drawn room leaves its config file on disk untouched,
  /// and removing a typed one destroys the only record of that room's date,
  /// life and figure. A mis-click there is a survey entry retyped from memory.
  /// See [restoreProjectManualRoom].
  ManualRoom? removeProjectManualRoom(String id) {
    final at = project.manualRooms.indexWhere((r) => r.id == id);
    if (at < 0) return null;
    final was = project.manualRooms[at];
    project.removeManualRoom(id);
    _logProjectEdit(
      itemKey: 'manual:$id',
      itemName: was.name,
      field: 'Line item',
      summary: 'taken off the plan',
    );
    _projectChanged();
    return was;
  }

  /// Puts a removed line back where it was - the undo of
  /// [removeProjectManualRoom]. Its id comes back with it, so anything that
  /// referred to the line still refers to the same line.
  void restoreProjectManualRoom(ManualRoom room, {int at = -1}) {
    if (project.manualRooms.any((r) => r.id == room.id)) return;
    final index = at < 0 || at > project.manualRooms.length
        ? project.manualRooms.length
        : at;
    project.manualRooms.insert(index, room);
    _logProjectEdit(
      itemKey: 'manual:${room.id}',
      itemName: room.name,
      field: 'Line item',
      summary: 'put back on the plan',
    );
    _projectChanged();
  }

  /// Where a line sits on the plan, or -1. What an undo needs to put it back
  /// in the same place rather than at the bottom.
  int projectManualRoomIndex(String id) =>
      project.manualRooms.indexWhere((r) => r.id == id);

  /// Replaces a typed-in line with the REAL room: the config file somebody has
  /// since drawn for it. Returns the message to show - '' when it went in.
  ///
  /// This is the point of a line item. A building arrives as thirty-four
  /// estimates and gets rebuilt one room at a time over several years, and the
  /// moment a room is drawn its estimate is the wrong number on the plan.
  /// Substituting is ONE action rather than two, because doing it as two - add
  /// the config, remember to delete the estimate - is how a room ends up
  /// counted twice in its own building's refresh total, at a figure that looks
  /// entirely plausible.
  ///
  /// THE LINE IS ONLY DROPPED IF THE CONFIG WENT ON. A room already on the job,
  /// or a file that is not there, leaves the plan exactly as it was: the
  /// estimate is the only record of that room, and losing it to a failed swap
  /// would take the room off the budget altogether.
  ///
  /// The typed name is carried onto the room as its label, because the plan is
  /// read by the code on the door - 'AGYM 129' - and the config's own name is
  /// as likely to be 'copy of lecture hall'.
  String swapManualRoomForConfig(String manualId, String configPath) {
    final at = project.manualRooms.indexWhere((r) => r.id == manualId);
    if (at < 0) return 'That line is no longer on the plan.';
    final line = project.manualRooms[at];

    final error = addRoomToProject(configPath, label: line.name.trim());
    if (error.isNotEmpty) return error;

    project.removeManualRoom(manualId);
    _logProjectEdit(
      itemKey: 'manual:$manualId',
      itemName: line.name,
      field: 'Line item',
      summary: 'replaced by ${path.basename(configPath)}',
    );
    AppLogger.logInfo(
      'Line item "${line.name}" swapped for the room config $configPath.',
    );
    _projectChanged();
    return '';
  }

  // --- the campus this job is on -------------------------------------------

  /// The campus sheet this job remembers, as an absolute path, or '' when it
  /// remembers none or the file it remembers is gone.
  ///
  /// CHECKED FOR EXISTENCE HERE rather than at the button. A campus folder that
  /// was renamed leaves every job in it pointing at nothing, and the honest
  /// behaviour then is the sheet of one - not an error about a file nobody
  /// asked to open. See [BuildingProject.campusFile].
  String get projectCampusFile {
    final resolved = project.resolvedCampusFile(currentProjectPath);
    if (resolved.isEmpty) return '';
    return File(resolved).existsSync() ? resolved : '';
  }

  /// Remembers [absolute] as the campus this job is on. '' forgets it.
  ///
  /// Not repricing: a pointer to another document cannot move a figure on this
  /// one.
  void setProjectCampusFile(String absolute) {
    final next = absolute.trim().isEmpty
        ? ''
        : BuildingProject.storeCampusPath(
            path.normalize(absolute.trim()),
            currentProjectPath,
          );
    if (next == project.campusFile) return;
    project.campusFile = next;
    _logProjectEdit(
      itemKey: 'project',
      itemName: project.name,
      field: 'Campus',
      summary: next.isEmpty
          ? 'no longer on a campus sheet'
          : 'on ${path.basename(next)}',
    );
    _projectChanged(repricing: false);
  }

  // --- building plans ------------------------------------------------------
  //
  //  The drawings the whole job refers to - see [ProjectPlan]. References,
  //  never copies: a plan set is reissued halfway through a job, and a copy
  //  taken in March is the drawing somebody installs the wrong thing from in
  //  June. Everything here works the way the room list does, for the same
  //  reasons, so a project travels with its drawings still attached.

  /// Where a plan actually is on this machine, resolved against the project
  /// file the same way a room's config path is. '' when the row has no path.
  String resolveProjectPlanPath(ProjectPlan plan) =>
      BuildingProject.resolvePath(plan.filePath, currentProjectPath);

  /// Whether the file behind a plan row is there. A drawing that has been
  /// moved or renamed is SAID to be missing rather than opening onto an
  /// error - "the file is gone" and "the viewer failed" are different
  /// problems with different fixes.
  bool projectPlanExists(ProjectPlan plan) {
    final resolved = resolveProjectPlanPath(plan);
    return resolved.isNotEmpty && File(resolved).existsSync();
  }

  /// Adds a drawing to the job. Returns the message to show - '' when it went
  /// in.
  ///
  /// The same file twice is refused: two rows onto one drawing is two places
  /// to write the note about it, and the second one is the one nobody reads.
  String addPlanToProject(String filePath, {String label = ''}) {
    if (filePath.isEmpty) return 'No file chosen.';
    final absolute = path.normalize(filePath);
    if (!File(absolute).existsSync()) {
      return 'There is no file at $absolute.';
    }
    for (final existing in project.plans) {
      if (path.equals(resolveProjectPlanPath(existing), absolute)) {
        return '${path.basename(absolute)} is already on this project.';
      }
    }

    final added = ProjectPlan(
      id: project.nextPlanId(),
      filePath: BuildingProject.storePath(absolute, currentProjectPath),
      label: label,
    );
    project.plans.add(added);
    _logProjectEdit(
      itemKey: 'plan:${added.id}',
      itemName: added.displayName,
      field: 'Plan',
      summary: 'added to the job',
    );
    AppLogger.logInfo('Building plan $absolute added to the project.');
    _projectChanged();
    return '';
  }

  /// Takes a drawing off the job. THE FILE IS UNTOUCHED - this list is a set
  /// of references, and deleting somebody's drawing set because they tidied a
  /// row off a list is not a thing this app is going to do.
  void removePlanFromProject(String planId) {
    final index = project.plans.indexWhere((p) => p.id == planId);
    if (index < 0) return;
    _logProjectEdit(
      itemKey: 'plan:$planId',
      itemName: project.plans[index].displayName,
      field: 'Plan',
      summary: 'removed from the job (its file is untouched)',
    );
    project.plans.removeAt(index);
    _projectChanged();
  }

  void updateProjectPlan(String planId, {String? label, String? notes}) {
    final index = project.plans.indexWhere((p) => p.id == planId);
    if (index < 0) return;
    final before = project.plans[index];
    project.plans[index] = before.copyWith(label: label, notes: notes);

    // One line per DECISION, not per keystroke - the same rule the room rows
    // are logged under.
    if (label != null && label.trim() != before.label.trim()) {
      _logProjectEdit(
        itemKey: 'plan:$planId',
        itemName: project.plans[index].displayName,
        field: 'Plan',
        summary: label.trim().isEmpty ? 'label cleared' : 'renamed',
        coalesce: true,
      );
    }
    if (notes != null && notes.trim() != before.notes.trim()) {
      _logProjectEdit(
        itemKey: 'plan:$planId',
        itemName: project.plans[index].displayName,
        field: 'Notes',
        summary: notes.trim().isEmpty ? 'cleared' : 'written',
        coalesce: true,
      );
    }
    _projectChanged();
  }

  /// Moves a drawing up or down the list - the order the set reads in.
  void moveProjectPlan(String planId, int delta) {
    final from = project.plans.indexWhere((p) => p.id == planId);
    if (from < 0) return;
    final to = from + delta;
    if (to < 0 || to >= project.plans.length) return;
    final plan = project.plans.removeAt(from);
    project.plans.insert(to, plan);
    _projectChanged();
  }

  /// Hands a plan to whatever the machine opens its file type with. Returns
  /// the message to show, or null when it opened.
  ///
  /// The way out for the formats the app cannot draw - a DWG, a Revit model -
  /// and the second opinion for the ones it can: a full CAD viewer has tools
  /// this one never will.
  Future<String?> openProjectPlanExternally(ProjectPlan plan) async {
    final resolved = resolveProjectPlanPath(plan);
    if (resolved.isEmpty || !File(resolved).existsSync()) {
      return '${plan.displayName} is not where the project says it is'
          '${resolved.isEmpty ? '' : ' ($resolved)'}.';
    }
    return openInDesktop(resolved);
  }

  // --- spares --------------------------------------------------------------
  //
  //  The spares the JOB buys, as opposed to the ones a room asks for on its own
  //  Cost tab. See [ProjectSpare] for where the line between the two is and
  //  why it is there.

  /// What one spare is called in the log: the part, and who it is for.
  String _spareLogName(ProjectSpare spare) => spare.forBuilding
      ? '${spare.description} (building spare)'
      : '${spare.description} (${projectRoomCode(spare.roomId)})';

  /// Adds a spare for [roomId], or for the building when [roomId] is ''.
  ProjectSpare addProjectSpare({
    required String partKey,
    required String description,
    String model = '',
    String manufacturer = '',
    String partNumber = '',
    double qty = 1,
    String roomId = '',
    String note = '',
  }) {
    final spare = project.addSpare(
      partKey: partKey,
      description: description,
      model: model,
      manufacturer: manufacturer,
      partNumber: partNumber,
      qty: qty,
      roomId: roomId,
      note: note,
    );
    _logProjectEdit(
      itemKey: projectPartItemKey(partKey),
      itemName: description,
      field: 'Spare',
      summary: spare.forBuilding
          ? '${trimNumber(spare.qty)} added for the building'
          : '${trimNumber(spare.qty)} added for '
              '${projectRoomCode(spare.roomId)}',
    );
    _projectChanged();
    return spare;
  }

  /// Puts ONE of every part in [lines] on the building's shelf.
  ///
  /// THE ONE DECISION THAT IS THE SAME ON EVERY ROW. "One spare of everything
  /// we install" is a policy plenty of jobs actually run, and until now it was
  /// carried out by pressing Add on two hundred rows in turn - which is how a
  /// job ends up with a shelf list that covers the first forty parts somebody
  /// had the patience for.
  ///
  /// FOR THE BUILDING, not for a room. A spare bought because the job installs
  /// the part at all belongs to the job; a spare bought for one room is a
  /// decision about that room, and it is made on that room's own page.
  ///
  /// Returns how many were added. One notify and one history line for the lot:
  /// two hundred separate entries would bury every other edit on the job.
  int addOneSpareOfEach(List<MasterPartLine> lines) {
    if (lines.isEmpty) return 0;
    for (final line in lines) {
      project.addSpare(
        partKey: line.key,
        // The part as it reads TODAY, so the row still says what it is after
        // every room has been swapped off this model.
        description: line.description,
        model: line.model,
        manufacturer: line.manufacturer,
        partNumber: line.partNumber,
        qty: 1,
        roomId: '',
        note: 'one of everything',
      );
    }
    _logProjectEdit(
      itemKey: 'project',
      itemName: project.name,
      field: 'Spares',
      summary: 'one each added for ${lines.length} '
          'part${lines.length == 1 ? '' : 's'}',
    );
    _projectChanged();
    return lines.length;
  }

  /// Changes how many of a spare the job is buying.
  void setProjectSpareQty(String spareId, double qty) {
    final before = project.spareById(spareId);
    if (before == null || before.qty == qty) return;
    project.updateSpare(spareId, qty: qty);
    final after = project.spareById(spareId)!;
    _logProjectEdit(
      itemKey: projectPartItemKey(after.partKey),
      itemName: _spareLogName(after),
      field: 'Spare',
      summary: 'set to ${trimNumber(after.qty)}',
      coalesce: true,
    );
    _projectChanged();
  }

  /// Moves a spare between a room and the building.
  ///
  /// [roomId] of '' is the building, and is the whole point: a spare somebody
  /// put against one room that turns out to be the shelf unit for the campus
  /// moves with one press rather than being deleted and retyped.
  void moveProjectSpare(String spareId, String roomId) {
    final before = project.spareById(spareId);
    if (before == null || before.roomId == roomId) return;
    project.updateSpare(spareId, roomId: roomId);
    final after = project.spareById(spareId)!;
    _logProjectEdit(
      itemKey: projectPartItemKey(after.partKey),
      itemName: after.description,
      field: 'Spare',
      summary: after.forBuilding
          ? 'moved off ${projectRoomCode(before.roomId)} to the building'
          : before.forBuilding
              ? 'moved from the building to ${projectRoomCode(roomId)}'
              : 'moved from ${projectRoomCode(before.roomId)} to '
                  '${projectRoomCode(roomId)}',
    );
    _projectChanged();
  }

  void setProjectSpareNote(String spareId, String note) {
    final spare = project.spareById(spareId);
    if (spare == null || spare.note.trim() == note.trim()) return;
    project.updateSpare(spareId, note: note);
    _logProjectEdit(
      itemKey: projectPartItemKey(spare.partKey),
      itemName: _spareLogName(spare),
      field: 'Spare',
      summary: note.trim().isEmpty ? 'note cleared' : 'note written',
      coalesce: true,
    );
    _projectChanged();
  }

  void removeProjectSpare(String spareId) {
    final spare = project.spareById(spareId);
    if (spare == null) return;
    project.removeSpare(spareId);
    _logProjectEdit(
      itemKey: projectPartItemKey(spare.partKey),
      itemName: _spareLogName(spare),
      field: 'Spare',
      summary: 'taken off the job',
    );
    _projectChanged();
  }

  // --- vendors -------------------------------------------------------------

  /// Adds a vendor AT THE TOP of the list.
  ///
  /// Where it lands is not cosmetic: a part is tagged by the first vendor
  /// whose rules claim it. Top is still the right place for a new one, for two
  /// reasons that point the same way.
  ///
  /// A vendor with no rules yet claims nothing, so arriving first changes no
  /// tag on the job the moment it appears. And the reason somebody presses Add
  /// is almost always that this vendor is the one that should win: 'buy Extron
  /// direct' is added to beat the reseller already on the list, and appended
  /// at the bottom it would lose to it until somebody noticed and walked it
  /// back up past six others.
  ///
  /// It is also simply where it can be seen. Appended to a list of nine, a new
  /// vendor arrives below the fold on the card somebody is looking at.
  ProjectVendor addProjectVendor({String name = 'New vendor'}) {
    final vendor = ProjectVendor(id: project.nextVendorId(), name: name);
    project.vendors.insert(0, vendor);
    _projectChanged();
    return vendor;
  }

  void updateProjectVendor(ProjectVendor vendor) {
    final index = project.vendors.indexWhere((v) => v.id == vendor.id);
    if (index < 0) return;
    project.vendors[index] = vendor;
    _projectChanged();
  }

  void removeProjectVendor(String vendorId) {
    project.removeVendor(vendorId);
    _projectChanged();
  }

  /// Moves a vendor up or down. Order is not cosmetic: it decides which vendor
  /// wins when two claim the same manufacturer or category — see
  /// [BuildingProject.vendorForPart].
  void moveProjectVendor(String vendorId, int delta) {
    final from = project.vendors.indexWhere((v) => v.id == vendorId);
    if (from < 0) return;
    final to = from + delta;
    if (to < 0 || to >= project.vendors.length) return;
    final vendor = project.vendors.removeAt(from);
    project.vendors.insert(to, vendor);
    _projectChanged();
  }

  /// Drops the vendor at [oldIndex] in at [newIndex] — the drag-and-drop
  /// version of [moveProjectVendor].
  ///
  /// Takes INDEXES rather than an id and a delta because that is what a
  /// reorderable list hands over. [newIndex] is the position in the list with
  /// the dragged row already taken OUT of it, which is what
  /// `SliverReorderableList.onReorderItem` passes — the older `onReorder`
  /// passed the un-adjusted index and left every caller to subtract one.
  void reorderProjectVendor(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= project.vendors.length) return;
    final to = newIndex.clamp(0, project.vendors.length - 1);
    if (to == oldIndex) return;
    final vendor = project.vendors.removeAt(oldIndex);
    project.vendors.insert(to, vendor);
    _logProjectEdit(
      itemKey: 'vendor:${vendor.id}',
      itemName: vendor.name,
      field: 'Priority',
      // The position is what the rule turns on, so the log says the position:
      // "moved" alone would not tell anybody why a part started going to a
      // different supplier.
      summary: 'moved to ${to + 1} of ${project.vendors.length}',
    );
    _projectChanged();
  }

  // --- the log ---------------------------------------------------------------
  //  Every decision made ON THE JOB goes through one of the setters below, so
  //  this is the one place that has to remember to record it. See
  //  [ProjectEdit] for what is logged and what deliberately is not.

  /// Records a change against an item and marks the project edited.
  ///
  /// [itemName] is the item as it reads RIGHT NOW, stored with the entry so
  /// the log still makes sense after the part is renamed or the room is taken
  /// off the job.
  /// [coalesce] for fields that write through on every keystroke — a note, a
  /// label. See [BuildingProject.logEdit].
  void _logProjectEdit({
    required String itemKey,
    required String field,
    required String summary,
    String itemName = '',
    bool coalesce = false,
  }) {
    project.logEdit(
      itemKey: itemKey,
      itemName: itemName,
      field: field,
      summary: summary,
      coalesce: coalesce,
    );
  }

  /// The log key and display name for one master-list part.
  static String projectPartItemKey(String partKey) => 'part:$partKey';

  // -------------------------------------------------------------------------
  //  WHAT A ROOM IS CALLED IN THE HISTORY
  // -------------------------------------------------------------------------
  //  'BSS 103 - Config'. The code on the door, then the file that was touched.
  //
  //  The log used to name rooms by their FILE STEM — 'BSS_101_config' — which
  //  is how the room is stored rather than what anybody calls it, and which
  //  says nothing at all about which of a room's five files an entry is about.
  //  A history is read months later by somebody who was not there, and it has
  //  to name things the way the work order does.

  /// The building code and room number for a room on the job, or its file
  /// stem when the config carries neither.
  ///
  /// Read from whatever is already in memory — the open room's config, or the
  /// project's cached read — and never off disk: this is called while a room
  /// is being renamed and while one is being removed, and a log line is not
  /// worth a file read.
  String projectRoomCode(String roomId) {
    final ref = project.roomById(roomId);
    if (ref == null) return '';

    final absolute = BuildingProject.resolvePath(
      ref.configPath,
      currentProjectPath,
    );
    final open = currentConfigPath.isNotEmpty &&
        _samePath(absolute, currentConfigPath);
    final code = open
        ? roomCodeFromConfig(roomConfig)
        : (_projectRooms[roomId]?.roomCode ?? '');
    return code.isNotEmpty ? code : ref.fallbackName;
  }

  /// How one entry names its room: the code, then the file, when there is a
  /// file to name. 'BSS 103 - Config', or plain 'BSS 103' for a decision about
  /// the room itself rather than about one of its files.
  String projectRoomLogName(String roomId, {String file = ''}) {
    final code = projectRoomCode(roomId);
    if (file.trim().isEmpty) return code;
    return code.isEmpty ? file.trim() : '$code - ${file.trim()}';
  }

  /// The room on the job that a config path belongs to, or null when the file
  /// open in the editor is not on this project at all.
  ProjectRoomRef? projectRefForConfig(String configPath) {
    if (configPath.trim().isEmpty) return null;
    for (final ref in project.rooms) {
      final absolute = BuildingProject.resolvePath(
        ref.configPath,
        currentProjectPath,
      );
      if (_samePath(absolute, configPath)) return ref;
    }
    return null;
  }

  /// What to call one of a room's files in the log: 'Config', 'AV flow',
  /// 'Racks', 'Floor plans', 'Cabling', 'Cost', 'Schematic'.
  ///
  /// Worked out from the suffix the file was written with rather than passed
  /// in by each caller, so a part renamed on disk cannot leave the log calling
  /// it by a name that no longer exists.
  static String roomFileLabel(String filePath) {
    final base = path.basenameWithoutExtension(filePath).toLowerCase();
    for (final part in RoomSidecarPart.values) {
      final suffix = kRoomSidecarSuffix[part];
      if (suffix != null && base.endsWith('_$suffix')) {
        return kRoomSidecarFileLabels[part] ?? suffix;
      }
    }
    if (base.endsWith('_schematic')) return 'Schematic';
    // The pre-rename diagram file, still on disk in older rooms.
    if (base.endsWith('_avflow')) return 'AV flow';
    return 'Config';
  }

  /// Records that a room's files were written, as ONE entry naming the room,
  /// the config, and whatever went with it.
  ///
  /// One entry per SAVE rather than one per file. Saving a room writes the
  /// config and up to five sidecars, and six rows per press would bury every
  /// decision on the job under the act of pressing Save.
  ///
  /// Silent when the saved room is not on the open project: there is no job
  /// for it to be part of the history of.
  void _logRoomSaved(String configPath, List<String> sidecars) {
    final ref = projectRefForConfig(configPath);
    if (ref == null) return;

    final also = <String>[
      for (final file in sidecars)
        if (file.trim().isNotEmpty) roomFileLabel(file),
    ]..sort();
    _logProjectEdit(
      itemKey: 'room:${ref.id}',
      itemName: projectRoomLogName(ref.id, file: 'Config'),
      field: 'Saved',
      summary: also.isEmpty
          ? 'to disk'
          : 'to disk, with the ${_readAsList(also)}',
    );
  }

  /// 'AV flow', 'AV flow and Cost', 'AV flow, Cost and Schematic' — a list a
  /// person would say out loud rather than one joined with commas to the end.
  static String _readAsList(List<String> items) {
    if (items.length <= 1) return items.join();
    return '${items.sublist(0, items.length - 1).join(', ')} and '
        '${items.last}';
  }

  /// Pins one master-list part to a vendor, or clears the pin (blank id) so it
  /// falls back to the rules.
  void pinProjectPart(String partKey, String vendorId, {String partName = ''}) {
    project.pinPart(partKey, vendorId);
    _logProjectEdit(
      itemKey: projectPartItemKey(partKey),
      itemName: partName,
      field: 'Vendor',
      summary: vendorId.isEmpty
          ? 'pin cleared - back to the vendor rules'
          : 'pinned to ${project.vendorById(vendorId)?.name ?? vendorId}',
    );
    _projectChanged();
  }

  // --- whose job each piece of it is ----------------------------------------
  //  The roles and responsibilities matrix. See responsibility_matrix.dart for
  //  what it is and why it is not derived from the rooms.

  /// Adds a line to the matrix and hands it back so the caller can open it for
  /// editing without looking it up again.
  ResponsibilityItem addResponsibilityItem([
    String scope = '',
    ({String furnishedBy, String installedBy, String work})? preset,
  ]) {
    final item = project.addResponsibilityItem(
      scope,
      furnishedBy: preset?.furnishedBy ?? '',
      installedBy: preset?.installedBy ?? '',
      work: preset?.work ?? '',
    );
    _logProjectEdit(
      itemKey: 'responsibility:${item.id}',
      itemName: item.scope,
      field: 'Responsibility matrix',
      summary: 'added',
    );
    _projectChanged(repricing: false);
    return item;
  }

  /// Replaces one line. The whole item rather than a field at a time, because
  /// the editor is a dialog that collects every field and commits once.
  void updateResponsibilityItem(ResponsibilityItem item) {
    final before = project.responsibilityById(item.id);
    project.updateResponsibilityItem(item);
    if (before != null) {
      // Said in terms of the two answers the document exists to record. A
      // history line reading "edited" would be true of every change and useful
      // for none of them.
      final parties = before.furnishedBy != item.furnishedBy ||
          before.installedBy != item.installedBy;
      _logProjectEdit(
        itemKey: 'responsibility:${item.id}',
        itemName: item.scope,
        field: 'Responsibility matrix',
        summary: parties
            ? 'furnished by ${item.furnishedBy.isEmpty ? 'nobody yet' : item.furnishedBy}, '
                'installed by ${item.installedBy.isEmpty ? 'nobody yet' : item.installedBy}'
            : 'updated',
      );
    }
    _projectChanged(repricing: false);
  }

  /// Sets how many of [itemId] one room needs, or takes the room off that line
  /// when [qty] is not positive.
  void setResponsibilityQty(String itemId, String roomId, double qty) {
    final item = project.responsibilityById(itemId);
    if (item == null) return;
    project.updateResponsibilityItem(item.withRoomQty(roomId, qty));
    _projectChanged(repricing: false);
  }

  void removeResponsibilityItem(String id) {
    final item = project.responsibilityById(id);
    if (item == null) return;
    project.removeResponsibilityItem(id);
    _logProjectEdit(
      itemKey: 'responsibility:$id',
      itemName: item.scope,
      field: 'Responsibility matrix',
      summary: 'removed',
    );
    _projectChanged(repricing: false);
  }

  void moveResponsibilityItem(String id, int delta) {
    project.moveResponsibilityItem(id, delta);
    _projectChanged(repricing: false);
  }

  /// Puts one line where a drag dropped it, and says so in the history.
  ///
  /// Logged where a step-at-a-time move is not: the order of this document is
  /// content - it is read top to bottom on site - and a column that moved
  /// across the sheet between two issues is a change somebody will ask about.
  void reorderResponsibilityItem(String id, int toIndex) {
    final before = project.responsibility.indexWhere((r) => r.id == id);
    project.reorderResponsibilityItem(id, toIndex);
    final after = project.responsibility.indexWhere((r) => r.id == id);
    if (after == before) return;
    final item = project.responsibilityById(id);
    if (item != null) {
      _logProjectEdit(
        itemKey: 'responsibility:$id',
        itemName: item.scope,
        field: 'Responsibility matrix',
        summary: 'moved to column ${after + 1}',
        coalesce: true,
      );
    }
    _projectChanged(repricing: false);
  }

  /// Puts the usual lines on the matrix. Returns how many were added, so the
  /// caller can say "nothing to add" rather than appearing to do nothing.
  int addStarterResponsibilityItems() {
    final added = project.addStarterResponsibilityItems();
    if (added == 0) return 0;
    _logProjectEdit(
      itemKey: 'responsibility',
      itemName: project.name,
      field: 'Responsibility matrix',
      summary: '$added starter line${added == 1 ? '' : 's'} added',
    );
    _projectChanged(repricing: false);
    return added;
  }

  // --- when the order has to go in ------------------------------------------
  //  Three setters and no computed dates: the order-by date on every row is
  //  derived from these on the spot (see project_schedule.dart), so moving the
  //  deadline moves the whole schedule instead of leaving stale dates behind.

  /// Sets the date the job needs everything delivered by, or clears it.
  void setProjectDeadline(DateTime? date) {
    project.deliveryDeadline = date == null ? null : dateOnly(date);
    _logProjectEdit(
      itemKey: 'project',
      itemName: project.name,
      field: 'Delivery deadline',
      summary: date == null
          ? 'cleared'
          : 'set to ${formatIsoDate(dateOnly(date))}',
    );
    AppLogger.logInfo(
      date == null
          ? 'Project delivery deadline cleared.'
          : 'Project delivery deadline set to ${formatIsoDate(dateOnly(date))}.',
    );
    _projectChanged();
  }

  /// Records how long one master-list part takes to arrive, in calendar days,
  /// or forgets the figure when [days] is null.
  void setProjectPartLeadTime(String partKey, int? days, {String partName = ''}) {
    final before = project.partLeadTimes[partKey];
    project.setPartLeadTime(partKey, days);
    final after = project.partLeadTimes[partKey];
    if (before != after) {
      _logProjectEdit(
        itemKey: projectPartItemKey(partKey),
        itemName: partName,
        field: 'Lead time',
        summary: after == null
            ? 'cleared - nobody has asked the vendor'
            : 'set to $after day${after == 1 ? '' : 's'}',
      );
    }
    _projectChanged();
  }

  /// Sets the date one master-list part has to arrive by, ahead of the rest of
  /// the job, or clears it so the part wants the project deadline again.
  void setProjectPartNeedBy(String partKey, DateTime? date, {String partName = ''}) {
    final before = project.partNeedBy[partKey];
    project.setPartNeedBy(partKey, date);
    final after = project.partNeedBy[partKey];
    if (before != after) {
      _logProjectEdit(
        itemKey: projectPartItemKey(partKey),
        itemName: partName,
        field: 'On site by',
        summary: after == null
            ? 'back to the job deadline'
            : 'wanted early, by ${formatIsoDate(after)}',
      );
    }
    _projectChanged();
  }

  // --- the phases a job delivers in -----------------------------------------
  //  A building is not finished on one date: the conduit and the mounts go in
  //  while the walls are open, the racks months later. See [ProjectTrack].

  /// Adds a delivery phase and hands it back.
  ProjectTrack addProjectTrack(String name, {DateTime? deadline}) {
    final track = project.addTrack(name, deadline: deadline);
    _logProjectEdit(
      itemKey: 'track:${track.id}',
      itemName: track.name,
      field: 'Phase',
      summary: 'added',
    );
    _projectChanged();
    return track;
  }

  /// Puts the usual two phases on a job that has none yet, and says how many
  /// it added — nothing when the job already has its own.
  int addStarterProjectTracks() {
    if (project.tracks.isNotEmpty) return 0;
    project.tracks.addAll(starterTracks(project));
    _projectChanged();
    return project.tracks.length;
  }

  void updateProjectTrack(ProjectTrack track) {
    project.updateTrack(track);
    _projectChanged();
  }

  void setProjectTrackDeadline(String id, DateTime? date) {
    project.setTrackDeadline(id, date);
    _logProjectEdit(
      itemKey: 'track:$id',
      itemName: project.trackById(id)?.name ?? '',
      field: 'Phase deadline',
      summary: date == null
          ? 'back to the job deadline'
          : 'set to ${formatIsoDate(dateOnly(date))}',
    );
    _projectChanged();
  }

  /// Sets one phase's completion date - when it is finished and handed over,
  /// as opposed to when its equipment has to arrive.
  void setProjectTrackCompletion(String id, DateTime? date) {
    project.setTrackCompletion(id, date);
    _logProjectEdit(
      itemKey: 'track:$id',
      itemName: project.trackById(id)?.name ?? '',
      field: 'Phase completion',
      summary: date == null
          ? 'no completion date'
          : 'set to ${formatIsoDate(dateOnly(date))}',
    );
    _projectChanged();
  }

  /// Moves a phase to a new place in the timeline - what a drag lands as.
  void moveProjectTrack(int from, int to) {
    if (from == to) return;
    final moved = from >= 0 && from < project.tracks.length
        ? project.tracks[from].name
        : '';
    project.moveTrack(from, to);
    _logProjectEdit(
      itemKey: 'track:order',
      itemName: moved,
      field: 'Phase order',
      summary: 'moved to position ${to + 1}',
    );
    _projectChanged();
  }

  /// Puts the phases in order of one of their two dates.
  ///
  /// A one-press ACTION on the stored order rather than a way of looking at
  /// it: the timeline is read in the order the work happens in, and a sort
  /// that only lived in the window would leave the file, the workbook and the
  /// screen disagreeing about what that order is.
  void sortProjectTracks({required bool byCompletion}) {
    project.sortTracksByDate(byCompletion: byCompletion);
    _logProjectEdit(
      itemKey: 'track:order',
      itemName: '',
      field: 'Phase order',
      summary: byCompletion ? 'sorted by completion date' : 'sorted by delivery date',
    );
    _projectChanged();
  }

  void removeProjectTrack(String id) {
    final was = project.trackById(id)?.name ?? '';
    project.removeTrack(id);
    _logProjectEdit(
      itemKey: 'track:$id',
      itemName: was,
      field: 'Phase',
      summary: 'removed',
    );
    _projectChanged();
  }

  /// Puts one master-list part on a phase, or back with the job when blank.
  void setProjectPartTrack(String partKey, String trackId, {String partName = ''}) {
    final before = project.partTracks[partKey];
    project.setPartTrack(partKey, trackId);
    if (before != project.partTracks[partKey]) {
      _logProjectEdit(
        itemKey: projectPartItemKey(partKey),
        itemName: partName,
        field: 'Phase',
        summary: trackId.isEmpty
            ? 'delivered with the job'
            : 'moved to ${project.trackById(trackId)?.name ?? trackId}',
      );
    }
    _projectChanged();
  }

  // --- what has actually been bought ----------------------------------------

  /// Records an order against one master-list part, or clears it when the
  /// record is empty. See [PartOrder].
  void setProjectPartOrder(String partKey, PartOrder? order, {String partName = ''}) {
    final before = project.orderForPart(partKey);
    project.setPartOrder(partKey, order);
    final after = project.orderForPart(partKey);

    // Only the transitions worth a line. Typing a PO number one character at a
    // time is one decision, not eleven, and a log that records every keystroke
    // is one nobody can read.
    final was = _orderStateOf(before);
    final now = _orderStateOf(after);
    if (was != now) {
      _logProjectEdit(
        itemKey: projectPartItemKey(partKey),
        itemName: partName,
        field: 'Order',
        summary: switch (now) {
          'received' => 'arrived'
              '${after?.receivedOn == null ? '' : ' on '
                  '${formatIsoDate(after!.receivedOn!)}'}',
          'ordered' => 'ordered'
              '${after?.orderedOn == null ? '' : ' on '
                  '${formatIsoDate(after!.orderedOn!)}'}'
              '${after?.poNumber.trim().isNotEmpty == true
                  ? ', PO ${after!.poNumber.trim()}'
                  : ''}',
          _ => 'order record cleared',
        },
      );
    }
    _projectChanged();
  }

  /// Which of the three states an order record is in, for deciding whether a
  /// change is worth logging.
  static String _orderStateOf(PartOrder? order) {
    if (order == null || !order.isOrdered) return 'none';
    return order.isReceived ? 'received' : 'ordered';
  }

  /// Marks a part ordered today, keeping whatever else is already on the
  /// record. The one-click case — the paperwork usually catches up later.
  void markProjectPartOrdered(String partKey, {DateTime? on}) {
    final existing = project.orderForPart(partKey) ?? const PartOrder();
    project.setPartOrder(
      partKey,
      existing.copyWith(orderedOn: dateOnly(on ?? DateTime.now())),
    );
    _projectChanged();
  }

  /// Marks a part received today. An arrival implies it was ordered, so a
  /// record that somehow has no order date gets one rather than sitting in a
  /// state that reads as "arrived without being bought".
  void markProjectPartReceived(String partKey, {DateTime? on}) {
    final when = dateOnly(on ?? DateTime.now());
    final existing = project.orderForPart(partKey) ?? const PartOrder();
    project.setPartOrder(
      partKey,
      existing.copyWith(
        receivedOn: when,
        orderedOn: existing.orderedOn ?? when,
      ),
    );
    _projectChanged();
  }

  // --- the purchase orders --------------------------------------------------

  /// The log key for one purchase order and one delivery.
  ///
  /// Both are their own kind rather than filed under the part, because a PO
  /// covers many parts and a delivery is a lot rather than a line — filing
  /// either under 'part:' would put "PO-1188 raised" on the history of
  /// whichever part happened to be first on it.
  static String projectPoItemKey(String id) => 'po:$id';
  static String projectDeliveryItemKey(String id) => 'delivery:$id';

  /// What a PO is called in the log — its number, which is the only name it
  /// has and the one everybody uses.
  static String _poLogName(ProjectPo po) =>
      po.number.trim().isEmpty ? 'PO' : po.number.trim();

  /// Adds a purchase order, or hands back the row the job already has for that
  /// number. See [BuildingProject.addPo].
  ProjectPo addProjectPo({
    String number = '',
    String vendorId = '',
    String vendor = '',
    DateTime? issuedOn,
    DateTime? expectedOn,
    double amount = 0,
  }) {
    final before = project.poByNumber(number);
    final po = project.addPo(
      number: number,
      vendorId: vendorId,
      vendor: vendor,
      issuedOn: issuedOn,
      expectedOn: expectedOn,
      amount: amount,
    );
    if (before == null) {
      _logProjectEdit(
        itemKey: projectPoItemKey(po.id),
        itemName: _poLogName(po),
        field: 'Purchase order',
        summary: po.issuedOn == null
            ? 'added to the job'
            : 'raised ${formatIsoDate(po.issuedOn!)}',
      );
      _projectChanged(repricing: false);
    }
    return po;
  }

  /// Replaces a PO row. [summary] says what changed, in the words the history
  /// will carry; nothing is logged without one, because a dialog that saves
  /// four untouched fields should not put four lines in the log.
  void updateProjectPo(ProjectPo po, {String summary = ''}) {
    project.updatePo(po);
    if (summary.isNotEmpty) {
      _logProjectEdit(
        itemKey: projectPoItemKey(po.id),
        itemName: _poLogName(po),
        field: 'Purchase order',
        summary: summary,
      );
    }
    _projectChanged(repricing: false);
  }

  /// Corrects a PO's number, carrying the parts and deliveries that named it
  /// across. False when the number is blank or already on another row — see
  /// [BuildingProject.renamePo].
  bool renameProjectPo(String id, String number) {
    final was = project.poById(id)?.number ?? '';
    if (!project.renamePo(id, number)) return false;
    final po = project.poById(id);
    if (po != null && normalizePoNumber(was) != normalizePoNumber(po.number)) {
      _logProjectEdit(
        itemKey: projectPoItemKey(id),
        itemName: _poLogName(po),
        field: 'Purchase order',
        summary: was.trim().isEmpty
            ? 'numbered ${po.number.trim()}'
            : 'renumbered from ${was.trim()}',
      );
    }
    _projectChanged(repricing: false);
    return true;
  }

  /// Takes a PO off the job's list. The parts keep the number they were bought
  /// on — see the note above [ProjectPo].
  void removeProjectPo(String id) {
    final po = project.poById(id);
    if (po == null) return;
    final onIt = project.partsOnPo(po.number).length;
    project.removePo(id);
    _logProjectEdit(
      itemKey: projectPoItemKey(id),
      itemName: _poLogName(po),
      field: 'Purchase order',
      summary: onIt == 0
          ? 'removed from the job'
          : 'removed from the job - $onIt part'
              '${onIt == 1 ? '' : 's'} still name it',
    );
    _projectChanged(repricing: false);
  }

  /// Signs a note onto a purchase order. The name and the time are taken, not
  /// typed — see [ProjectNote].
  void addProjectPoNote(String id, String text) {
    if (text.trim().isEmpty) return;
    if (!project.addPoNote(id, ProjectNote.now(text))) return;
    final po = project.poById(id);
    _logProjectEdit(
      itemKey: projectPoItemKey(id),
      itemName: po == null ? 'PO' : _poLogName(po),
      field: 'Purchase order',
      summary: 'note added',
    );
    _projectChanged(repricing: false);
  }

  // --- what has arrived and where it is -------------------------------------

  /// What a delivery is called in the log: what turned up, and how many.
  static String _deliveryLogName(ProjectDelivery row) {
    final name = row.itemName.trim();
    final qty = formatUnits(row.qty);
    if (name.isEmpty) return qty.isEmpty ? 'Delivery' : '$qty units';
    return qty.isEmpty ? name : '$qty x $name';
  }

  /// Logs an arrival. See [BuildingProject.addDelivery].
  ProjectDelivery addProjectDelivery({
    String partKey = '',
    String itemName = '',
    String poNumber = '',
    double qty = 0,
    DateTime? deliveredOn,
    DeliveryState state = DeliveryState.delivered,
    String location = '',
    String roomId = '',
    DateTime? installedOn,
    String note = '',
  }) {
    final row = project.addDelivery(
      partKey: partKey,
      itemName: itemName,
      poNumber: poNumber,
      qty: qty,
      deliveredOn: deliveredOn,
      state: state,
      location: location,
      roomId: roomId,
      installedOn: installedOn,
      note: note.trim().isEmpty ? null : ProjectNote.now(note),
    );
    // A PO NAMED ON A DELIVERY JOINS THE JOB'S PO LIST, the same as one typed
    // onto a part - see [showPartScheduleDialog]. A packing slip is often the
    // first place a PO number is read off, and a list that only knows the
    // numbers somebody remembered to enter twice cannot answer what is on one.
    if (row.poNumber.trim().isNotEmpty) {
      project.addPo(number: row.poNumber);
    }
    _logProjectEdit(
      itemKey: projectDeliveryItemKey(row.id),
      itemName: _deliveryLogName(row),
      field: 'Delivery',
      summary: [
        row.deliveredOn == null
            ? 'arrived'
            : 'arrived ${formatIsoDate(row.deliveredOn!)}',
        if (row.poNumber.trim().isNotEmpty) 'on ${row.poNumber.trim()}',
        '- ${row.state.phrase}',
      ].join(' '),
    );
    _projectChanged(repricing: false);
    return row;
  }

  /// Replaces a delivery row. [summary] says what changed; nothing is logged
  /// without one, for the reason [updateProjectPo] gives.
  void updateProjectDelivery(ProjectDelivery row, {String summary = ''}) {
    project.updateDelivery(row);
    if (summary.isNotEmpty) {
      _logProjectEdit(
        itemKey: projectDeliveryItemKey(row.id),
        itemName: _deliveryLogName(row),
        field: 'Delivery',
        summary: summary,
      );
    }
    _projectChanged(repricing: false);
  }

  /// Moves a lot to a new state — into storage, into a room, back to the
  /// vendor. The one gesture the tracker is opened for, so it is one call
  /// rather than a copyWith at every call site.
  ///
  /// GOING INTO A ROOM DATES ITSELF. An install with no date is a row that
  /// cannot answer "when did that go in", and the day it is recorded is the
  /// right answer often enough that asking for it every time would be friction
  /// people route around by not recording the install at all. It can still be
  /// corrected on the row.
  void setProjectDeliveryState(
    String id,
    DeliveryState state, {
    String location = '',
    String roomId = '',
    DateTime? on,
  }) {
    final row = project.deliveryById(id);
    if (row == null) return;
    final when = dateOnly(on ?? DateTime.now());
    final moved = row.copyWith(
      state: state,
      // The location is only overwritten when one is given: a lot that goes
      // from storage into a room keeps saying where it had been.
      location: location.trim().isEmpty ? null : location.trim(),
      roomId: state == DeliveryState.installed ? roomId : '',
      installedOn: state == DeliveryState.installed ? when : null,
      clearInstalledOn: state != DeliveryState.installed,
    );
    project.updateDelivery(moved);
    if (row.state != state ||
        row.roomId != moved.roomId ||
        row.location != moved.location) {
      _logProjectEdit(
        itemKey: projectDeliveryItemKey(id),
        itemName: _deliveryLogName(moved),
        field: 'Delivery',
        summary: switch (state) {
          DeliveryState.installed =>
            'installed ${formatIsoDate(when)}'
                '${moved.roomId.isEmpty ? '' : ' in ${projectRoomLogName(moved.roomId)}'}',
          DeliveryState.stored => moved.location.trim().isEmpty
              ? 'moved into storage'
              : 'moved into storage - ${moved.location.trim()}',
          DeliveryState.returned => 'sent back to the vendor',
          DeliveryState.delivered => 'marked as on site',
        },
      );
    }
    _projectChanged(repricing: false);
  }

  void removeProjectDelivery(String id) {
    final row = project.deliveryById(id);
    if (row == null) return;
    project.removeDelivery(id);
    _logProjectEdit(
      itemKey: projectDeliveryItemKey(id),
      itemName: _deliveryLogName(row),
      field: 'Delivery',
      summary: 'record removed',
    );
    _projectChanged(repricing: false);
  }

  /// Signs a note onto a delivery. The name and the time are taken, not typed
  /// — see [ProjectNote].
  void addProjectDeliveryNote(String id, String text) {
    if (text.trim().isEmpty) return;
    if (!project.addDeliveryNote(id, ProjectNote.now(text))) return;
    final row = project.deliveryById(id);
    _logProjectEdit(
      itemKey: projectDeliveryItemKey(id),
      itemName: row == null ? 'Delivery' : _deliveryLogName(row),
      field: 'Delivery',
      summary: 'note added',
    );
    _projectChanged(repricing: false);
  }

  void removeProjectDeliveryNote(String id, int index) {
    if (!project.removeDeliveryNote(id, index)) return;
    _projectChanged(repricing: false);
  }

  /// How many calendar exports this session has produced, incremented.
  ///
  /// Goes into the ICS SEQUENCE field, which is how a calendar recognises a
  /// re-exported file as a REVISION of the events it already imported rather
  /// than as a second set of them. Without a rising number, moving a deadline
  /// and exporting again leaves the old dates sitting in somebody's calendar
  /// beside the new ones — worse than having exported nothing.
  ///
  /// Session-scoped rather than saved: the events are matched by uid, and the
  /// only requirement on the sequence is that it rises within a run of
  /// exports. Persisting it would put a counter in the project file that
  /// nothing else has any use for.
  int _reminderSequence = 0;

  int nextReminderSequence() => ++_reminderSequence;

  // --- the job's to-do list -------------------------------------------------

  /// Adds a note to the job's list. Blank text does nothing.
  ///
  /// A note is about the job, or about one room, or about something somebody
  /// typed — [roomId] and [scopeLabel] are the second and third, and naming a
  /// room wins over a label.
  void addProjectTodo(
    String text, {
    String roomId = '',
    String scopeLabel = '',
  }) {
    final id = project.addTodo(text, roomId: roomId, scopeLabel: scopeLabel);
    if (id.isEmpty) return;
    _logProjectEdit(
      itemKey: 'todo:$id',
      itemName: text.trim(),
      field: 'Job list',
      summary: 'added',
    );
    _projectChanged();
  }

  void setProjectTodoState(String id, ProjectTodoState state) {
    project.setTodoState(id, state);
    _logProjectEdit(
      itemKey: 'todo:$id',
      itemName: _todoTextOf(id),
      field: 'Job list',
      summary: switch (state) {
        ProjectTodoState.done => 'marked done',
        ProjectTodoState.blocked => 'waiting on somebody else',
        ProjectTodoState.open => 'back on the list',
      },
    );
    _projectChanged();
  }

  /// One note's text, for naming it in the log. '' when it has gone.
  String _todoTextOf(String id) {
    for (final t in project.todos) {
      if (t.id == id) return t.text;
    }
    return '';
  }

  void setProjectTodoText(String id, String text) {
    project.setTodoText(id, text);
    _projectChanged();
  }

  void setProjectTodoRoom(String id, String roomId) {
    project.setTodoRoom(id, roomId);
    _projectChanged();
  }

  /// Files one note under a typed scope, or blank to put it back on the job.
  void setProjectTodoScopeLabel(String id, String label) {
    project.setTodoScopeLabel(id, label);
    _projectChanged();
  }

  /// Sets the date one note has to be done by, or clears it.
  void setProjectTodoDue(String id, DateTime? date) {
    project.setTodoDue(id, date);
    _logProjectEdit(
      itemKey: 'todo:$id',
      itemName: _todoTextOf(id),
      field: 'Job list',
      summary: date == null
          ? 'date taken off'
          : 'due ${formatIsoDate(dateOnly(date))}',
    );
    _projectChanged();
  }

  void removeProjectTodo(String id) {
    // Named BEFORE it goes, or the entry that records the removal cannot say
    // what was removed.
    final was = _todoTextOf(id);
    project.removeTodo(id);
    _logProjectEdit(
      itemKey: 'todo:$id',
      itemName: was,
      field: 'Job list',
      summary: 'removed',
    );
    _projectChanged();
  }

  /// Drops every finished note, and says how many went.
  int clearDoneProjectTodos() {
    final gone = project.clearDoneTodos();
    if (gone > 0) _projectChanged();
    return gone;
  }



  // --- is this room behind its file? ---------------------------------------

  /// The room as it stood the last time it was loaded or saved.
  ///
  /// A fingerprint rather than a flag. A flag would have to be set by every
  /// mutation in this class — hundreds of them, across the wizard, the device
  /// forms, the canvas, the racks and the estimate — and the one that got
  /// missed would be the one that lost somebody's work silently.
  ///
  /// Comparing the document to itself cannot be forgotten to do. It costs an
  /// encode of the room, so it is asked ON DEMAND — when somebody is about to
  /// leave the room — and never per frame.
  String _savedRoomFingerprint = '';

  /// The last answer [_roomFingerprint] gave, or null when it has to work it
  /// out again.
  ///
  /// WHY MEMOISE. [roomHasUnsavedChanges] is read by the SaveToolbar (see
  /// save_actions.dart), which is in the title bar of every tab, so it is
  /// asked on EVERY rebuild —
  /// and a rebuild is what each of the two hundred [notifyListeners] calls in
  /// this class causes, including the one [updateDeviceValue] makes per
  /// keystroke. Encoding the whole room to answer "is there a dot on the save
  /// button" was measured at 5.5ms a frame while somebody typed.
  ///
  /// WHY THIS IS NOT THE FLAG THE COMMENT ON [_savedRoomFingerprint] WARNS
  /// ABOUT. That warning is about a dirty flag SET by each of the hundreds of
  /// mutations — one missed setter and work is lost silently. This is dropped
  /// in ONE place, [notifyListeners], which every mutation already goes
  /// through in order to be visible on screen at all: a change that skipped it
  /// would not have reached the toolbar to be asked about either. It is the
  /// same hook, for the same reason, as the memoised [_projectEstimate].
  String? _cachedRoomFingerprint;

  /// Drops the memoised fingerprint. Called from [notifyListeners].
  void _forgetRoomFingerprint() => _cachedRoomFingerprint = null;

  String _roomFingerprint() {
    final cached = _cachedRoomFingerprint;
    if (cached != null) return cached;
    try {
      return _cachedRoomFingerprint =
          jsonEncode(_sortJson(_pruneConfig(roomConfig))) +
              jsonEncode(avFlowAsJson());
    } catch (_) {
      // A room that cannot be encoded is a room we cannot compare; treat it as
      // changed so the prompt errs towards keeping work rather than losing it.
      //
      // DELIBERATELY NOT CACHED. Two calls have to disagree for the room to
      // read as changed — caching the timestamp would make [markRoomSaved] and
      // the check below agree on it, and an unencodable room would report
      // itself clean, which is the one answer this branch exists to avoid.
      return DateTime.now().microsecondsSinceEpoch.toString();
    }
  }

  /// Records the room as matching its files — called after a load and after a
  /// save.
  ///
  /// Takes the fingerprint FRESH. This is the baseline every later comparison
  /// is made against, and it is asked a handful of times a session rather than
  /// a hundred times a second, so it pays for itself rather than trusting a
  /// cache it did not fill.
  void markRoomSaved() {
    _forgetRoomFingerprint();
    _savedRoomFingerprint = _roomFingerprint();
  }

  /// True when the room in memory differs from the files it came from.
  ///
  /// Covers the config AND the sidecars, because "unsaved work" on this app is
  /// as often a diagram or a typed price as it is a field on a form.
  bool get roomHasUnsavedChanges =>
      currentConfigPath.isNotEmpty &&
      _savedRoomFingerprint.isNotEmpty &&
      _roomFingerprint() != _savedRoomFingerprint;

  /// Writes the room back over the file it came from, with no dialog, and its
  /// sidecars with it.
  ///
  /// Export Config asks where to put it, which is right for producing a copy
  /// and wrong for the thing somebody does forty times an afternoon while
  /// moving between the rooms of a job. Returns the file written, or a message
  /// beginning with 'Error' — the caller shows either.
  ///
  /// ONE implementation, shared with the toolbar's Save button. It used to be
  /// a second one: this wrote the PRUNED config and took no backup, while
  /// [saveCurrentConfigToFile] wrote the full one and left a `_previous.json`
  /// to undo from. Which of the two you got depended on whether you had
  /// pressed Save in the title bar or Save in the room picker, and only one of
  /// them could be undone — a difference nobody could see and nobody chose.
  Future<String> saveRoomInPlace() async {
    if (currentConfigPath.isEmpty) {
      return 'Error: this room has never been saved, so there is no file to '
          'save it back to. Use Save Room As once to give it one.';
    }
    if (roomConfig.isEmpty) return 'Error: there is nothing to save.';
    try {
      final written = await saveCurrentConfigToFile();
      if (written == null) {
        return 'Error: this room has no working file to save back to.';
      }
      AppLogger.logInfo('Room saved in place to $written.');
      return written;
    } catch (e, stack) {
      AppLogger.logError('Failed to save the room to $currentConfigPath', e,
          stack);
      return 'Error: $e';
    }
  }

  // --- working on a room of the project ------------------------------------

  /// The project room the editor currently holds, or null.
  ///
  /// Derived from [currentConfigPath] rather than remembered separately. A
  /// second copy of "which room is open" is a second thing to keep in step,
  /// and it would be wrong the first time somebody opened one of the project's
  /// rooms through the ordinary Open Config dialog — which should light up the
  /// picker exactly as if they had chosen it there.
  ProjectRoomRef? get openProjectRoom {
    if (currentConfigPath.isEmpty) return null;
    for (final ref in project.rooms) {
      final absolute = BuildingProject.resolvePath(
        ref.configPath,
        currentProjectPath,
      );
      if (absolute.isNotEmpty && _samePath(absolute, currentConfigPath)) {
        return ref;
      }
    }
    return null;
  }

  /// Two paths naming the same file, allowing for Windows' case-insensitivity
  /// and for one of them being spelled with different separators.
  static bool _samePath(String a, String b) {
    final left = path.normalize(a).replaceAll('\\', '/');
    final right = path.normalize(b).replaceAll('\\', '/');
    return Platform.isWindows
        ? left.toLowerCase() == right.toLowerCase()
        : left == right;
  }

  /// Opens one of the project's rooms into the editor.
  ///
  /// The whole room, not just the config: the sidecars are read straight away
  /// rather than waiting for somebody to visit the AV Flow tab. Switching
  /// rooms from a picker means the NEXT tab you look at is as likely to be
  /// Racks or Cost as the diagram, and a room that half-arrives — control
  /// config from the new room, drawing still from the old one — is the worst
  /// possible version of this feature.
  ///
  /// Loading the sidecars here also settles [avFlowNeedsChoice] before it can
  /// fire. That prompt exists for "you have an unsaved diagram and the file
  /// you opened has one too"; on a deliberate room switch the answer is always
  /// the room being switched to, and asking would be noise on every hop.
  ///
  /// Returns the message to show, or '' when it worked.
  Future<String> openProjectRoomRef(ProjectRoomRef ref) async {
    final absolute = BuildingProject.resolvePath(
      ref.configPath,
      currentProjectPath,
    );
    if (absolute.isEmpty) return 'That room has no file on the project.';
    if (!File(absolute).existsSync()) {
      return 'The config is not at $absolute.';
    }

    final ok = await openConfigAtPath(absolute);
    if (!ok) return 'Could not open $absolute - see the log.';

    loadAvFlowForCurrentConfig();

    // Both the room being left and the room being opened are now better read
    // live than from the cache: the one being left may have unsaved edits the
    // cache never saw, and the one being opened is about to be priced from
    // memory instead.
    _projectRooms.clear();

    AppLogger.logInfo(
      'Project room "${ref.fallbackName}" opened into the editor from '
      '$absolute.',
    );
    notifyListeners();
    return '';
  }

  /// Steps to the next or previous room on the project, skipping nothing —
  /// including the rooms excluded from the total, which are still rooms
  /// somebody works on.
  ///
  /// Returns the message to show, or '' when it worked.
  Future<String> stepProjectRoom(int delta) async {
    if (project.rooms.isEmpty) return 'This project has no rooms yet.';
    final current = openProjectRoom;
    final from = current == null
        ? -1
        : project.rooms.indexWhere((r) => r.id == current.id);
    // From nowhere, forward lands on the first room and back on the last.
    final next = from < 0
        ? (delta > 0 ? 0 : project.rooms.length - 1)
        : (from + delta) % project.rooms.length;
    return openProjectRoomRef(
      project.rooms[next < 0 ? next + project.rooms.length : next],
    );
  }

  /// The open room as the rollup should see it: from MEMORY, not from disk.
  ///
  /// This is what makes an edit on a room tab show up in the building total
  /// without a save-and-refresh round trip. A price typed on the Cost tab, a
  /// box added to the diagram, a device given its module — all of it reaches
  /// the project on the next rebuild, because the project reads the same
  /// objects the room tabs are editing rather than the file underneath them.
  ///
  /// The room's own file is of course still behind until somebody saves, and
  /// the Rooms pane says so on the row rather than letting the figure quietly
  /// disagree with what is on disk.
  LoadedRoom _liveRoom(String configPath) {
    final setup = roomConfig['SYSTEM_SETUP'];
    final title =
        (setup is Map ? setup['gui_full_room_name']?.toString() : '')?.trim() ??
            '';
    return LoadedRoom(
      configPath: configPath,
      title: title,
      // The same three collections readRoomFromDisk builds a model out of —
      // the ones costing and the control-gap rule actually read.
      model: AvFlowModel(
        nodes: List<AvNode>.from(avNodes),
        cables: List<AvCable>.from(avCables),
        racks: List<RackFrame>.from(avRacks),
        rackSlots: const {},
        rackItems: List<RackItem>.from(avRackItems),
        canvasSize: Size.zero,
        roomTitle: title,
        unplaced: const [],
      ),
      settings: avCost,
      config: roomConfig,
      flowPath: avFlowSidecarPath,
    );
  }

  // --- pricing -------------------------------------------------------------

  /// Forgets the cached read of ONE room — the one whose file just changed
  /// under this app.
  ///
  /// Saving a room used to drop the whole cache, so the next price re-read
  /// every file on the job to discover what the app already knew: exactly one
  /// of them had moved. On a forty-room building that is thirty-nine rooms of
  /// file reads per save.
  ///
  /// Falls back to dropping everything when there is no path to match on,
  /// because a cache that might be stale and cannot be checked is one to throw
  /// away.
  void _forgetCachedRoom(String configPath) {
    if (configPath.trim().isEmpty) {
      _projectRooms.clear();
      return;
    }
    final byId = {for (final r in project.rooms) r.id: r};
    _projectRooms.removeWhere((id, _) {
      final ref = byId[id];
      // A room that has left the project keeps no cache entry either way.
      if (ref == null) return true;
      return _samePath(
        BuildingProject.resolvePath(ref.configPath, currentProjectPath),
        configPath,
      );
    });
  }

  /// Forgets the cached room reads, so the next estimate re-reads every file.
  /// Called when the project's rooms change and by the Refresh button — a room
  /// saved in another window is a change this app cannot be told about.
  void refreshProjectRooms() {
    _projectRooms.clear();
    notifyListeners();
  }

  /// Drops the memoised estimate on the way out of every mutation.
  ///
  /// Overridden rather than hooked at each call site because there are two
  /// hundred of them: a cache that has to be invalidated by hand in two
  /// hundred places is a cache that is wrong in one of them. See
  /// [_projectEstimate].
  @override
  void notifyListeners() {
    // Consumed here whether or not it was set, so a flag can never outlive the
    // one change it was set for.
    if (_keepEstimate) {
      _keepEstimate = false;
    } else {
      _projectEstimate = null;
    }
    // The room's fingerprint goes the same way and for the same reason: this
    // is the one place every mutation passes through. See
    // [_cachedRoomFingerprint].
    _forgetRoomFingerprint();
    super.notifyListeners();
  }

  /// Prices the project.
  ///
  /// [fresh] re-reads every room from disk; otherwise rooms already read this
  /// session are reused. The default is the cached read because this is called
  /// on every rebuild of the Project tab — tagging a part re-prices, and
  /// re-reading forty files to answer "which column does this row go in" would
  /// make the tab feel broken.
  ProjectEstimate priceProject({bool fresh = false}) {
    if (fresh) {
      _projectRooms.clear();
      _projectEstimate = null;
    }
    // Worked out once per change rather than once per build — see
    // [_projectEstimate] for why that is safe.
    final cached = _projectEstimate;
    if (cached != null) return cached;

    final rooms = <String, LoadedRoom>{};
    for (final ref in project.rooms) {
      final absolute = BuildingProject.resolvePath(
        ref.configPath,
        currentProjectPath,
      );
      // The room in the editor is read from MEMORY and never cached: it is
      // being edited, so a copy of it is out of date the moment it is taken,
      // and the file underneath it is out of date until somebody saves.
      if (currentConfigPath.isNotEmpty && _samePath(absolute, currentConfigPath)) {
        rooms[ref.id] = _liveRoom(absolute);
        _projectRooms.remove(ref.id);
        continue;
      }
      rooms[ref.id] =
          _projectRooms[ref.id] ??= readRoomFromDisk(absolute);
    }
    // Rooms that have left the project should not keep their files cached.
    _projectRooms.removeWhere(
      (id, _) => !project.rooms.any((r) => r.id == id),
    );

    return _projectEstimate = computeProjectEstimate(
      project: project,
      projectPath: currentProjectPath,
      library: avDeviceLibrary,
      rates: laborRates,
      baseCosts: baseCosts,
      tier: pricingTier,
      rooms: rooms,
      // The control-module rule needs application data the rollup has no way
      // to reach on its own: which config sections a family's count makes
      // live, and which python module claims a model.
      deviceCountMap: uiSchema.deviceCountMap,
      moduleForModel: moduleForModel,
    );
  }

  // --- swapping a product across the building ------------------------------

  /// Works out what swapping [fromModel] to [template] would do to every room
  /// on the project. Writes nothing — see [applyProjectModelSwap].
  ProjectSwapPlan planProjectModelSwap(
    String fromModel,
    AvDeviceTemplate template,
  ) {
    // Deliberately a FRESH read. A plan is shown to somebody who is about to
    // authorise writing to nine files, and showing it off a cache that could
    // be minutes old would be showing them a picture of a building that no
    // longer exists.
    _projectRooms.clear();
    return planProjectSwap(
      project: project,
      projectPath: currentProjectPath,
      fromModel: fromModel,
      template: template,
      moduleForModel: moduleForModel,
      deviceCountMap: uiSchema.deviceCountMap,
      openConfigPath: currentConfigPath,
    );
  }

  /// Carries out [plan].
  ///
  /// Every room but the open one is written on disk. The OPEN one is applied
  /// through the normal in-memory path instead, so it lands on the undo stack
  /// like any other swap and the editor and the file cannot disagree — writing
  /// its files here would put the swap on disk and leave the old model in
  /// memory, ready for the next Save to quietly undo it.
  ({ProjectSwapResult disk, int openRoomBoxes, bool openRoomDirty})
  applyProjectModelSwap(ProjectSwapPlan plan) {
    final disk = applyProjectSwap(
      plan: plan,
      moduleForModel: moduleForModel,
      deviceCountMap: uiSchema.deviceCountMap,
    );

    var openBoxes = 0;
    for (final room in plan.affectedRooms) {
      if (!room.isOpenRoom) continue;
      for (final id in room.nodeIds) {
        final node = avNodeById(id);
        if (node == null) continue;
        // One undo entry for the whole swap, not one per box.
        applyModelSwap(this, node, plan.to, recordUndo: openBoxes == 0);
        openBoxes++;
      }
      applyControlSwap(this, room.nodeIds, plan.to.model);
    }

    // Whatever was just written is not what the cache holds.
    _projectRooms.clear();
    notifyListeners();
    return (
      disk: disk,
      openRoomBoxes: openBoxes,
      openRoomDirty: openBoxes > 0,
    );
  }

  /// Every manufacturer and category the catalog knows, for the vendor rule
  /// pickers. Sorted and de-duplicated; the catalog is the only place these
  /// strings are authoritative, and typing them by hand is how a rule ends up
  /// matching nothing.
  ({List<String> manufacturers, List<String> categories}) get catalogFacets {
    final makers = <String>{};
    final categories = <String>{};
    for (final entry in avDeviceLibrary.all) {
      final m = entry.manufacturer.trim();
      if (m.isNotEmpty) makers.add(m);
      final c = entry.category.trim();
      if (c.isNotEmpty) categories.add(c);
    }
    final makerList = makers.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final categoryList = categories.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return (manufacturers: makerList, categories: categoryList);
  }

  // ==========================================================================
  //  WHAT IS NOT ON DISK
  // ==========================================================================
  //  Three documents can be behind their files at once — the room, the project
  //  that lists it, and the room that has no file at all. Every "are you sure"
  //  in the app asks the same question, so the answer is written once, as
  //  SENTENCES rather than as a bool: a prompt that says "there are unsaved
  //  changes" and a prompt that says "BSS103_config.json has edits and the
  //  project has two new rooms" are the same dialog doing very different
  //  amounts of good.
  // ==========================================================================

  /// True when the room on screen has never been written anywhere.
  ///
  /// Distinct from [roomHasUnsavedChanges], which compares against a file and
  /// so is false for a room that has none. Both are unsaved work; only this
  /// one cannot be answered by writing over something.
  bool get roomNeverSaved => roomConfig.isNotEmpty && currentConfigPath.isEmpty;

  /// One line per document that is behind its file, in the order somebody
  /// would deal with them. Empty when everything is saved.
  List<String> get unsavedWorkSummary {
    final out = <String>[];
    if (roomNeverSaved) {
      out.add('This room has never been saved - it has no file yet.');
    } else if (roomHasUnsavedChanges) {
      out.add('${path.basename(currentConfigPath)} has edits that are not in '
          'the file - a field, a box on a drawing, a price, or all three.');
    }
    if (projectDirty) {
      out.add('The project "$projectDisplayName" has edits that are not on '
          'disk - the room list, the vendors or the tags.');
    }
    return out;
  }

  /// True when anything at all would be lost by quitting now.
  bool get hasUnsavedWork => unsavedWorkSummary.isNotEmpty;

  // ==========================================================================
  //  AUTOSAVE — A LIVE WORKING COPY YOU CAN GET BACK
  // ==========================================================================
  //  The timer writes the open job into a RECOVERY COPY: a small folder of
  //  ordinary files, one per document, in the app's own settings directory.
  //  It never touches the user's files. Saving is what does that — and a save
  //  deletes the recovery copy afterwards, because a copy of work that is
  //  already in its file is a copy that can only ever mislead somebody.
  //
  //  So the copy exists exactly while there is unsaved work, and its existence
  //  is the signal. There are three ways it stops existing:
  //
  //    * the document is saved — the file now holds it;
  //    * the user closes the app and chooses "close without saving" — they
  //      said discard, and being asked again on Monday is not helping;
  //    * the user discards it at the recovery prompt described below.
  //
  //  A CRASH IS NONE OF THOSE. Nothing deletes the copy, so it is still there
  //  the next time that file is opened — and [pendingRecovery] catches it,
  //  compares it to what was just loaded, and offers the difference the same
  //  way the conversion log offers a migration: a list of every property that
  //  would change, before anything changes.
  //
  //  The slot is keyed by the document's own path, so the check on reopen is a
  //  lookup rather than a search, and two rooms both called config.json in
  //  different folders cannot collide.
  // ==========================================================================

  /// The intervals the App Config dropdown offers, in minutes.
  static const List<int> kAutosaveIntervals = [1, 2, 5, 10, 15, 30];

  /// The manifest written into every recovery slot.
  static const String kRecoveryManifest = 'recovery.json';

  static int _sanitizeAutosaveMinutes(dynamic raw) {
    final n = raw is int ? raw : (int.tryParse(raw?.toString() ?? '') ?? 5);
    return n < 1 ? 1 : (n > 240 ? 240 : n);
  }

  Timer? _autosaveTimer;

  /// When the last recovery copy was written; null until one has been.
  DateTime? lastAutosaveAt;

  /// The folder the last recovery copy went into ('' until one has been
  /// written, and cleared again when a save retires it).
  String lastAutosaveFolder = '';

  /// Why the last recovery copy failed, '' when it did not.
  String lastAutosaveError = '';

  /// The fingerprint the last copy was taken of, so an idle hour does not
  /// rewrite the same four files two hundred times.
  String _lastAutosaveFingerprint = '';

  /// Where the recovery copies live: `<settings folder>/recovery`.
  ///
  /// Beside app_config.json rather than beside the room, because a working
  /// copy that lands in the stakeholder's project folder is a file somebody
  /// emails to the stakeholder by mistake — and because a folder the app owns is
  /// one it can still find after the room has been moved or renamed.
  String get autosaveFolder =>
      _autosaveFolderOverride ?? path.join(_userSettingsDir(), 'recovery');

  /// Redirects the recovery copies into a temp folder for a test. Also what
  /// makes [writeAutosaveSnapshot] willing to write at all on a
  /// test-constructed provider — without it, a test that took a copy would
  /// drop folders into the developer's own %APPDATA%.
  String? _autosaveFolderOverride;

  @visibleForTesting
  set autosaveFolderForTest(String folder) => _autosaveFolderOverride = folder;

  /// (Re)starts the timer from the current settings. Safe to call repeatedly.
  void _restartAutosaveTimer() {
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
    // Test-constructed providers never touch the filesystem, and a timer left
    // running past the end of a test fails it.
    if (!_persistenceEnabled || !autosaveEnabled) return;
    _autosaveTimer = Timer.periodic(
      Duration(minutes: autosaveMinutes),
      (_) => writeAutosaveSnapshot(),
    );
  }

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
    super.dispose();
  }

  // --- where a document's recovery copy lives ------------------------------

  /// A short, stable tag for [originPath] — its own name plus a hash of the
  /// full path.
  ///
  /// The name is there so somebody looking in the folder can see which room is
  /// which; the hash is there because two buildings both holding a plain
  /// `config.json` are the normal case, not the exotic one, and a slot named
  /// after the file alone would have them overwriting each other's recovery.
  /// Hashed case-insensitively, since Windows treats the two spellings of a
  /// path as the same file.
  static String recoverySlotName(String originPath) {
    final stem = path.basenameWithoutExtension(originPath);
    final safe = stem.replaceAll(RegExp('[^A-Za-z0-9_.-]+'), '_');
    // FNV-1a, 32-bit. Not a security hash — just a short, stable spreading of
    // the path across the folder.
    int hash = 0x811c9dc5;
    for (final unit in originPath.toLowerCase().codeUnits) {
      hash = (hash ^ unit) & 0xFFFFFFFF;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return '${safe.isEmpty ? 'untitled' : safe}_'
        '${hash.toRadixString(16).padLeft(8, '0')}';
  }

  /// The room's recovery slot, or '' when the room has never been saved and so
  /// has no path to key one on.
  String get roomRecoveryFolder => currentConfigPath.isEmpty
      ? ''
      : path.join(
          autosaveFolder, 'rooms', recoverySlotName(currentConfigPath));

  /// The project's recovery slot, or '' when the project has no file yet.
  String get projectRecoveryFolder => currentProjectPath.isEmpty
      ? ''
      : path.join(
          autosaveFolder, 'projects', recoverySlotName(currentProjectPath));

  /// Where a room with no file of its own keeps its copy.
  ///
  /// Nothing can offer it back automatically — there is no file to open and
  /// compare it against — but a session that crashed before its first save is
  /// exactly the session whose work is worth the most, so it is written
  /// anyway, and App Config's "Open backup folder" is how it is found.
  String get _untitledRecoveryFolder => path.join(
      autosaveFolder, 'rooms', 'untitled_${_untitledStem()}');

  String _untitledStem() {
    final setup = roomConfig['SYSTEM_SETUP'];
    final bldg = (setup is Map ? setup['gve_bldg']?.toString() : '') ?? '';
    final room = (setup is Map ? setup['gve_room']?.toString() : '') ?? '';
    final stem = '${bldg.trim()}_${room.trim()}'
        .replaceAll(RegExp('[^A-Za-z0-9_.-]+'), '_')
        .replaceAll(RegExp('^_+|_+\$'), '');
    return stem.isEmpty ? 'room' : stem;
  }

  /// The stem every file in the room's copy is named from — the working file's
  /// own name when there is one, else the building and room.
  String get autosaveStem => currentConfigPath.isEmpty
      ? '${_untitledStem()}_config'
      : path.basenameWithoutExtension(currentConfigPath);

  /// What the copy is a copy OF.
  String _autosaveFingerprint() {
    try {
      return '$currentConfigPath|$currentProjectPath|'
          '${_roomFingerprint()}|${jsonEncode(project.toJson())}';
    } catch (_) {
      return DateTime.now().microsecondsSinceEpoch.toString();
    }
  }

  // --- writing it ----------------------------------------------------------

  /// Writes the recovery copy of everything that is behind its file.
  ///
  /// Returns the room's slot (or the project's, when only the project is
  /// behind), or '' when there was nothing to copy, nothing had changed since
  /// the last copy, or the write failed — [lastAutosaveError] carries the
  /// reason in that last case.
  ///
  /// [force] copies even when nothing has changed, which is what "Back up now"
  /// in App Config does.
  Future<String> writeAutosaveSnapshot({bool force = false}) async {
    // A test provider writes only where a test has told it to.
    if (!_persistenceEnabled && _autosaveFolderOverride == null) return '';

    // ONLY UNSAVED WORK IS COPIED. A recovery copy of a document that matches
    // its file would be offered back on the next open as "these two differ" —
    // and they would not.
    final bool roomLoose = roomNeverSaved || roomHasUnsavedChanges;
    if (!roomLoose && !projectDirty) return '';

    final fingerprint = _autosaveFingerprint();
    if (!force && fingerprint == _lastAutosaveFingerprint) return '';

    // Whatever is half-typed in the raw editor belongs in the copy too — it is
    // the one place edits sit outside roomConfig.
    pendingRawEditorCommit?.call();

    String written = '';
    try {
      if (roomLoose) {
        written = await _writeRoomRecovery();
      }
      if (projectDirty) {
        final projectSlot = await _writeProjectRecovery();
        if (written.isEmpty) written = projectSlot;
      }
      _lastAutosaveFingerprint = fingerprint;
      lastAutosaveAt = DateTime.now();
      lastAutosaveFolder = written;
      lastAutosaveError = '';
      notifyListeners();
      return written;
    } catch (e, stack) {
      lastAutosaveError = '$e';
      AppLogger.logError('Could not write the recovery copy', e, stack);
      notifyListeners();
      return '';
    }
  }

  Future<String> _writeRoomRecovery() async {
    final folder = currentConfigPath.isEmpty
        ? _untitledRecoveryFolder
        : roomRecoveryFolder;
    await Directory(folder).create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    final written = <String>[];

    // The files carry exactly the names they would beside a real config, so a
    // recovery by hand is a copy of the folder rather than a renaming exercise
    // performed by somebody having a bad day.
    final configName = '$autosaveStem.json';
    await File(path.join(folder, configName)).writeAsString(
      encoder.convert(_sortJson(_pruneConfig(roomConfig))),
    );
    written.add(configName);

    final parts = splitRoomSidecar(avFlowAsJson());
    for (final part in RoomSidecarPart.values) {
      final name = path.basename(
        roomSidecarPath(path.join(folder, configName), part),
      );
      await File(path.join(folder, name))
          .writeAsString(encoder.convert(parts[part]));
      written.add(name);
    }

    if (hasSchematicLayout) {
      final name = '${autosaveStem}_control_schematic.json';
      await File(path.join(folder, name))
          .writeAsString(encoder.convert(schematicLayoutAsJson()));
      written.add(name);
    }

    await File(path.join(folder, kRecoveryManifest)).writeAsString(
      encoder.convert({
        '__readme': 'Recovery copy written by the Room Config Builder while '
            'this room had unsaved changes. It is offered back the next time '
            'the room below is opened; nothing here is applied automatically.',
        'kind': 'room',
        'origin': currentConfigPath,
        'takenAt': DateTime.now().toLocal().toIso8601String(),
        'configFile': configName,
        'files': written,
      }),
    );
    AppLogger.logInfo(
        'Recovery copy of the room written to $folder (${written.length} '
        'files).');
    return folder;
  }

  Future<String> _writeProjectRecovery() async {
    if (currentProjectPath.isEmpty) return '';
    final folder = projectRecoveryFolder;
    await Directory(folder).create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    final name = path.basename(currentProjectPath);
    await File(path.join(folder, name))
        .writeAsString(encoder.convert(project.toJson()));
    await File(path.join(folder, kRecoveryManifest)).writeAsString(
      encoder.convert({
        '__readme': 'Recovery copy of a Room Config Builder project with '
            'unsaved changes. Offered back the next time the project below is '
            'opened.',
        'kind': 'project',
        'origin': currentProjectPath,
        'takenAt': DateTime.now().toLocal().toIso8601String(),
        'projectFile': name,
        'files': [name],
      }),
    );
    AppLogger.logInfo('Recovery copy of the project written to $folder.');
    return folder;
  }

  // --- retiring it ---------------------------------------------------------

  /// Deletes a recovery slot. Failures are logged and swallowed — a folder
  /// that will not delete must never break a save.
  ///
  /// Synchronous, and deliberately so. Every caller is at a moment where the
  /// answer matters immediately — a load deciding whether to prompt, a save
  /// deciding the copy is spent — and a handful of small files is not worth an
  /// unawaited future that can still be in flight when the next question is
  /// asked about the same folder.
  void _clearRecoveryFolder(String folder) {
    if (folder.isEmpty) return;
    try {
      final dir = Directory(folder);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
        AppLogger.logInfo('Retired the recovery copy at $folder.');
      }
      if (lastAutosaveFolder == folder) lastAutosaveFolder = '';
      // The next tick must be free to write a fresh copy rather than deciding
      // nothing has changed since the one just deleted.
      _lastAutosaveFingerprint = '';
    } catch (e) {
      AppLogger.logError('Could not remove the recovery copy at $folder', e);
    }
  }

  /// Called after the room reaches its file. The copy has done its job.
  void clearRoomRecovery() => _clearRecoveryFolder(roomRecoveryFolder);

  /// Called after the project reaches its file.
  void clearProjectRecovery() => _clearRecoveryFolder(projectRecoveryFolder);

  /// All of them, for "close without saving": the user said discard, and a
  /// prompt about it on Monday is second-guessing them.
  void clearAllRecovery() {
    clearRoomRecovery();
    clearProjectRecovery();
    _clearRecoveryFolder(_untitledRecoveryFolder);
  }

  // --- finding it again ----------------------------------------------------

  /// A recovery copy that outlived the session that wrote it, waiting to be
  /// offered back. Null whenever there is nothing to offer.
  RecoveryFind? pendingRecovery;

  /// Drops the pending offer without touching the files — "not now".
  void dismissPendingRecovery() {
    pendingRecovery = null;
    notifyListeners();
  }

  /// Throws the pending recovery copy away for good.
  void discardPendingRecovery() {
    final folder = pendingRecovery?.folder ?? '';
    pendingRecovery = null;
    _clearRecoveryFolder(folder);
    notifyListeners();
  }

  /// Reads the recovery slot for [originPath], or null when there is none.
  ///
  /// Whole-folder read rather than file-by-file on demand: the caller is about
  /// to diff every part of it, and a half-read recovery copy is worse than
  /// none — it would report the missing halves as deletions.
  RecoveryFind? readRecoverySlot(String folder, String kind) {
    if (folder.isEmpty) return null;
    final manifestFile = File(path.join(folder, kRecoveryManifest));
    if (!manifestFile.existsSync()) return null;
    try {
      final manifest = jsonDecode(manifestFile.readAsStringSync());
      if (manifest is! Map || manifest['kind'] != kind) return null;

      Map<String, dynamic>? read(String name) {
        if (name.isEmpty) return null;
        final f = File(path.join(folder, name));
        if (!f.existsSync()) return null;
        final doc = jsonDecode(f.readAsStringSync());
        return doc is Map ? Map<String, dynamic>.from(doc) : null;
      }

      final takenAt =
          DateTime.tryParse(manifest['takenAt']?.toString() ?? '') ??
              manifestFile.lastModifiedSync();

      if (kind == 'project') {
        final doc = read(manifest['projectFile']?.toString() ?? '');
        if (doc == null) return null;
        return RecoveryFind(
          kind: 'project',
          folder: folder,
          origin: manifest['origin']?.toString() ?? '',
          takenAt: takenAt,
          document: doc,
        );
      }

      final configName = manifest['configFile']?.toString() ?? '';
      final config = read(configName);
      if (config == null) return null;

      // The sidecars come back merged into the one document the app reads, so
      // the comparison and the restore both work on the shape the rest of the
      // app already speaks.
      final stem = path.basenameWithoutExtension(configName);
      final parts = <RoomSidecarPart, Map<String, dynamic>?>{
        for (final part in RoomSidecarPart.values)
          part: read('${stem}_${kRoomSidecarSuffix[part]}.json'),
      };
      return RecoveryFind(
        kind: 'room',
        folder: folder,
        origin: manifest['origin']?.toString() ?? '',
        takenAt: takenAt,
        document: config,
        flow: parts.values.any((p) => p != null)
            ? mergeRoomSidecar(parts)
            : <String, dynamic>{},
        schematic: read('${stem}_control_schematic.json') ?? const {},
      );
    } catch (e) {
      AppLogger.logError('Could not read the recovery copy at $folder', e);
      return null;
    }
  }

  /// Looks for a recovery copy of the room that was just opened, and holds it
  /// in [pendingRecovery] when it says something different from the file.
  ///
  /// Called TWICE on every open, and the reason is the two halves of a room.
  /// The config arrives first ([openConfigAtPath]) and the drawings, racks,
  /// plans and estimate arrive with the sidecars a moment later
  /// ([loadAvFlowForCurrentConfig]) — and either half can be the one a crash
  /// left behind. So the first pass compares what it has and never throws
  /// anything away; only the pass with the whole room in hand
  /// ([sidecarsLoaded]) is entitled to decide that a copy is redundant and
  /// retire it. A single check at either point would either miss a lost
  /// drawing or delete the copy of one.
  void checkForRoomRecovery({bool sidecarsLoaded = true}) {
    pendingRecovery = null;
    if (currentConfigPath.isEmpty) return;
    final found = readRecoverySlot(roomRecoveryFolder, 'room');
    if (found == null) return;

    final deltas = recoveryDeltas(
      currentConfig: _sortJson(_pruneConfig(roomConfig)),
      currentFlow: sidecarsLoaded ? avFlowAsJson() : found.flow,
      found: found,
    );
    if (deltas.isEmpty) {
      // Saved before the crash after all — retire it quietly, but only once
      // the whole room has been read: a config that matches says nothing yet
      // about the drawing beside it.
      if (sidecarsLoaded) _clearRecoveryFolder(found.folder);
      return;
    }
    pendingRecovery = found.withDeltas(deltas);
    AppLogger.logInfo(
        'A recovery copy of $currentConfigPath from ${found.takenAt} differs '
        'from the file in ${deltas.length} place'
        '${deltas.length == 1 ? '' : 's'}.');
    notifyListeners();
  }

  /// The project's counterpart, called at the end of [openProject].
  void checkForProjectRecovery() {
    pendingRecovery = null;
    if (currentProjectPath.isEmpty) return;
    final found = readRecoverySlot(projectRecoveryFolder, 'project');
    if (found == null) return;

    final deltas = diffConfigs(
      _asDiffable(project.toJson()),
      _asDiffable(found.document),
    );
    if (deltas.isEmpty) {
      _clearRecoveryFolder(found.folder);
      return;
    }
    pendingRecovery = found.withDeltas(deltas);
    notifyListeners();
  }

  /// [diffConfigs] compares a map of BLOCKS. A project's JSON is a flat mix of
  /// scalars and lists, so each top-level value is wrapped in a block of its
  /// own — which is also what makes the resulting lines read as
  /// "rooms — [4 items] would go back to [3 items]".
  static Map<String, dynamic> _asDiffable(Map<String, dynamic> doc) => {
        for (final e in doc.entries)
          if (e.key != '__readme') e.key: e.value,
      };

  /// Every property that differs between the room on screen and a recovery
  /// copy of it — the list the recovery dialog shows before anything changes.
  ///
  /// The config is compared property by property. The room's other document —
  /// the drawings, racks, plans, cabling and estimate — is compared at its top
  /// level instead: "nodes — [12 items] would become [13 items]" is the honest
  /// summary of a drawing, and walking into every box to list the ones that
  /// moved would produce a page nobody reads.
  @visibleForTesting
  static List<ConfigDelta> recoveryDeltas({
    required Map<String, dynamic> currentConfig,
    required Map<String, dynamic> currentFlow,
    required RecoveryFind found,
  }) {
    final deltas = diffConfigs(currentConfig, found.document);

    const labels = {
      'nodes': 'Signal flow',
      'cables': 'Signal flow',
      'racks': 'Racks',
      'rackItems': 'Racks',
      'rackSlots': 'Racks',
      'locations': 'Floor plan',
      'floorPlans': 'Floor plan',
      'screenSwitches': 'Cabling',
      'cablingSchematic': 'Cabling',
      'cost': 'Cost estimate',
    };

    final keys = <String>{...currentFlow.keys, ...found.flow.keys}
      ..remove('__readme')
      // THE LOG IS NOT A DIFFERENCE. Two copies of a room that differ only in
      // how many edits each of them remembers are the same room, and a
      // recovery prompt raised over that is a prompt with nothing behind it —
      // which is exactly the dialog this comparison exists to avoid. The log
      // still travels with the copy and is still restored with it; it just
      // does not get a vote on whether there is anything to restore.
      ..remove('roomHistory');
    for (final key in keys.toList()..sort()) {
      final before = currentFlow[key];
      final after = found.flow[key];
      if (jsonEncode(before) == jsonEncode(after)) continue;
      deltas.add(ConfigDelta(
        section: labels[key] ?? 'Room document',
        key: key,
        kind: !currentFlow.containsKey(key)
            ? DeltaKind.added
            : !found.flow.containsKey(key)
                ? DeltaKind.removed
                : DeltaKind.changed,
        before: before,
        after: after,
      ));
    }
    return deltas;
  }

  /// Puts a recovery copy back — INTO MEMORY, not onto disk.
  ///
  /// The file is left exactly as it was. That is deliberate: the user has just
  /// been shown a list of differences and said "yes, that one", and the next
  /// thing they should do is look at the room before committing it. Save is
  /// what writes it, as it is for every other edit — and the Save button lights
  /// its unsaved dot the moment this returns, which is the honest state.
  void applyRecovery(RecoveryFind found) {
    if (found.kind == 'project') {
      project = BuildingProject.fromJson(found.document);
      projectDirty = true;
      _projectRooms.clear();
      pendingRecovery = null;
      AppLogger.logInfo(
          'Recovered the project from ${found.folder} (taken '
          '${found.takenAt}). The file is untouched until it is saved.');
      notifyListeners();
      return;
    }

    roomConfig = Map<String, dynamic>.from(found.document);
    _bumpConfigRevision();

    _resetAvFlow();
    if (found.flow.isNotEmpty) _readAvFlowJson(found.flow);
    _avFlowSyncedPath = currentConfigPath;

    _resetSchematicLayout();
    if (found.schematic.isNotEmpty) {
      _readSchematicJson(Map<String, dynamic>.from(found.schematic));
    }
    _schematicSyncedPath = currentConfigPath;

    pendingRecovery = null;
    AppLogger.logInfo(
        'Recovered the room from ${found.folder} (taken ${found.takenAt}). '
        '$currentConfigPath is untouched until it is saved.');
    notifyListeners();
  }

  /// Opens the recovery folder in the file manager, creating it first when no
  /// copy has been written yet.
  ///
  /// Its own method rather than [revealInFileManager], which expects a FILE and
  /// would open the parent of a folder handed to it — here that would be the
  /// settings directory, one level away from what the button says.
  Future<String?> openAutosaveFolder() async {
    try {
      await Directory(autosaveFolder).create(recursive: true);
    } catch (e, stack) {
      AppLogger.logError('Could not create $autosaveFolder', e, stack);
      return 'Could not create $autosaveFolder';
    }
    return openInDesktop(autosaveFolder);
  }
}

/// A recovery copy read back off disk, with everything the prompt needs to
/// describe it and everything [AppStateProvider.applyRecovery] needs to put it
/// back.
class RecoveryFind {
  /// 'room' or 'project'.
  final String kind;

  /// The slot it was read from.
  final String folder;

  /// The file it is a copy of, as recorded when it was written.
  final String origin;

  /// When the copy was taken.
  final DateTime takenAt;

  /// The config (room) or the project JSON.
  final Map<String, dynamic> document;

  /// The room's merged sidecar document — drawings, racks, plans, cabling,
  /// estimate. Empty for a project, and for a room that had none.
  final Map<String, dynamic> flow;

  /// The room's control schematic layout. Empty when there was none.
  final Map<String, dynamic> schematic;

  /// Every property that differs from what is on screen. Filled in by
  /// [withDeltas] once the comparison has been made.
  final List<ConfigDelta> deltas;

  const RecoveryFind({
    required this.kind,
    required this.folder,
    required this.origin,
    required this.takenAt,
    required this.document,
    this.flow = const {},
    this.schematic = const {},
    this.deltas = const [],
  });

  RecoveryFind withDeltas(List<ConfigDelta> found) => RecoveryFind(
        kind: kind,
        folder: folder,
        origin: origin,
        takenAt: takenAt,
        document: document,
        flow: flow,
        schematic: schematic,
        deltas: found,
      );

  /// What to call the document in the prompt.
  String get noun => kind == 'project' ? 'project' : 'room';
}

/// Where a value in the working config came from. Drives the coloring in the
/// conversion preview and on the Devices / System tabs; the palette itself
/// lives in conversion_colors.dart.
enum ValueOrigin {
  /// Carried over from the file that was loaded, untouched — shown in ORANGE,
  /// because nobody has confirmed it against the current template yet.
  legacy,

  /// The key came from the loaded file but the conversion REWROTE the value:
  /// gve_bldg normalized to its building code, the module resolved from the
  /// model, the generated room name replacing the placeholder. Shown in TEAL —
  /// it is neither purely the old file's value nor purely the template's, and
  /// calling it "from the old file" (which is what the single orange used to
  /// say) points the tech at the wrong thing when they come to check it.
  changed,

  /// Written by the conversion from the template, the schema defaults or a
  /// lookup — shown in the theme's ordinary text color.
  written,
}

/// What a conversion did to one property, so the preview can show it and the
/// user can reject it individually.
enum ConversionKind { added, removed, changed }

/// A single reversible change the conversion made, as shown in the preview.
///
/// [before] is the value in the loaded file (null when the key is new),
/// [after] the value now (null when the key was removed). Rejecting a change
/// puts [before] back; accepting leaves [after] in place.
class ConversionChange {
  final String section;
  final String key;
  final ConversionKind kind;
  final dynamic before;
  final dynamic after;

  /// Set when the property was dropped as invalid where it sat (an
  /// ip_address on a serial device) rather than merely superseded.
  final String? conflictReason;

  /// False once the user rejects it in the preview.
  bool accepted;

  ConversionChange({
    required this.section,
    required this.key,
    required this.kind,
    this.before,
    this.after,
    this.conflictReason,
    this.accepted = true,
  });

  String get id => '$section.$key';
  bool get isConflict => conflictReason != null;

  /// How the change reads in the preview list: 'SECTION.key', or just the name
  /// for a scalar sitting at the root of the file (which has no key).
  String get label => key.isEmpty ? section : '$section.$key';

  /// One-line summary for the preview list.
  String get description {
    String show(dynamic v) {
      if (v == null) return 'null';
      final s = v.toString();
      if (s.isEmpty) return '""';
      return s.length > 60 ? '${s.substring(0, 57)}...' : s;
    }

    switch (kind) {
      case ConversionKind.added:
        return 'Added - written as ${show(after)}';
      case ConversionKind.removed:
        return conflictReason != null
            ? 'Removed (${conflictReason!}) - was ${show(before)}'
            : 'Removed - was ${show(before)}';
      case ConversionKind.changed:
        return '${show(before)} → ${show(after)}';
    }
  }
}

/// One entry of the model registry: which python module a model name maps
/// to, whether that mapping came from an explicit DEVICE_INFO dict
/// (authoritative) or was only inferred from the driver's self.Models keys,
/// and which device-family tabs offer it (empty = every tab).
class ModelEntry {
  final String model;
  final String module;
  final bool explicit;

  /// Raw "device_type" strings from DEVICE_INFO (e.g. 'projector',
  /// 'display'); matched against the ui_schema families at filter time.
  final List<String> deviceTypes;

  const ModelEntry(
      {required this.model,
      required this.module,
      required this.explicit,
      this.deviceTypes = const []});
}

/// The result of AppStateProvider.previewModelSelection: what selecting a
/// model would do, computed without mutating the config, so the view can ask
/// the user whether to apply the module defaults or keep the current settings.
class ModelChangePreview {
  /// True when the model is claimed by a module in the registry.
  final bool known;

  /// The module the selected model maps to ('' when unknown).
  final String newModule;

  /// True when applying would switch the device to a different module.
  final bool moduleChanged;

  /// The module's DEVICE_INFO defaults resolved for this device (trailing
  /// index substituted; site-specific blanks kept). Excludes model/module.
  final Map<String, dynamic> resolvedDefaults;

  /// Fields whose current value differs from the resolved module default.
  final List<FieldDiff> diffs;

  const ModelChangePreview({
    required this.known,
    required this.newModule,
    required this.moduleChanged,
    required this.resolvedDefaults,
    required this.diffs,
  });
}

/// One field that differs between a device's current value and the module
/// default, listed in the Model-change dialog.
class FieldDiff {
  final String key;
  final dynamic current;
  final dynamic moduleDefault;
  const FieldDiff(
      {required this.key, required this.current, required this.moduleDefault});
}

/// What happened to one property between two versions of a config, read in
/// the "after" direction: [added] exists only in the newer one, [removed] only
/// in the older, [changed] in both with different values.
enum DeltaKind { added, changed, removed }

/// One difference between two configs (AppStateProvider.diffConfigs) — the
/// per-property lines the Undo dialog lists before restoring a backup.
class ConfigDelta {
  /// The config block, e.g. 'PROJECTORDEVICE_1'.
  final String section;

  /// The property inside it; '' when the whole section (or a root scalar)
  /// is what differs.
  final String key;

  final DeltaKind kind;
  final dynamic before;
  final dynamic after;

  const ConfigDelta({
    required this.section,
    required this.key,
    required this.kind,
    this.before,
    this.after,
  });

  /// 'PROJECTORDEVICE_1.speaker_mute', or just the section for a whole-block
  /// difference.
  String get label => key.isEmpty ? section : '$section.$key';

  /// One line for the dialog: what restoring the backup would do to this
  /// property, written from the file's point of view.
  String get summary {
    String show(dynamic v) {
      if (v == null) return 'null';
      if (v is Map) return '{${v.length} propert${v.length == 1 ? 'y' : 'ies'}}';
      if (v is List) return '[${v.length} item${v.length == 1 ? '' : 's'}]';
      return v is String ? '"$v"' : v.toString();
    }

    switch (kind) {
      case DeltaKind.added:
        return '$label - added by the save, would be removed: ${show(after)}';
      case DeltaKind.removed:
        return '$label - removed by the save, would come back: ${show(before)}';
      case DeltaKind.changed:
        return '$label - ${show(after)} would go back to ${show(before)}';
    }
  }
}