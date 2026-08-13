import 'app_state.dart';

/// ============================================================================
///  WHAT THE DRIVER SAYS THIS MODEL WANTS
/// ============================================================================
///  A conversion fills a device block from two places: the FAMILY defaults in
///  key_map.json ("every wireless device is SSH"), and a hand-maintained
///  template block matched on the model string. Neither knows anything about
///  the driver that will actually run the device.
///
///  That is fine until the two disagree, and they disagree exactly where it
///  costs a commissioning visit:
///
///    * a VIA GO converts to SSH, because the wireless family default is SSH
///      (the ShareLink is), while krmr_VIA_GO.py says TCP on port 9982;
///    * an AP7921B converts with no module and no keep-alive trigger, because
///      the template block that carries those spells the model "AP7900B" —
///      one of the three the same driver serves;
///    * a converted room's connection details are simply whatever the legacy
///      file had, and nothing ever offers the driver's own.
///
///  The driver's DEVICE_INFO is the authority on all of it: it is written by
///  whoever wrote the code that talks to the box. This works out where a room
///  disagrees with it, so the conversion can ASK — the same question the model
///  picker asks when somebody chooses a model by hand, put to the whole file at
///  once.
///
///  Nothing here writes: it reports, and the dialog applies what is ticked.
/// ============================================================================

/// The keys that describe HOW the processor reaches a device and keeps the
/// connection alive.
///
/// Ticked by default in the review, because they are facts about the model
/// rather than about this room — the port a VIA GO listens on is the same port
/// in every building. Everything else the driver supplies (its naming, its
/// GUI ids) is left unticked: a converted room has already been named, and the
/// driver's own `name` would undo that.
const Set<String> kConnectionDefaultKeys = {
  'module',
  'com_type',
  'protocol',
  'net_port',
  'service_port',
  'host',
  'baud',
  'keep_alive_command',
  'keep_alive_interval',
  'keep_alive_trigger',
  'keep_alive_qualifier',
  'manual_disconnect',
  'auto_reconnect',
};

/// One property a device disagrees with its driver about.
class ModelDefaultDiff {
  final String key;
  final dynamic current;
  final dynamic fromModule;

  /// True when this is one of [kConnectionDefaultKeys] — ticked by default.
  final bool connection;

  const ModelDefaultDiff({
    required this.key,
    required this.current,
    required this.fromModule,
    required this.connection,
  });

  /// True when the device simply does not carry the key yet.
  bool get isAddition => current == null || current.toString().isEmpty;

  String get currentText =>
      isAddition ? '(not set)' : current.toString();

  String get proposedText => fromModule?.toString() ?? '';
}

/// One device whose block disagrees with the driver its model names.
class ModelDefaultMismatch {
  /// Config section — 'POWERDEVICE_1'.
  final String sectionKey;

  /// What the block calls itself, for the dialog's row title.
  final String name;
  final String model;

  /// The driver the registry gives this model, in the dotted import spelling
  /// the config stores.
  final String module;

  final List<ModelDefaultDiff> diffs;

  const ModelDefaultMismatch({
    required this.sectionKey,
    required this.name,
    required this.model,
    required this.module,
    required this.diffs,
  });

  /// The keys ticked when the review opens.
  Set<String> get defaultSelection => {
    for (final d in diffs)
      if (d.connection) d.key,
  };
}

/// Every device in the loaded room whose block disagrees with the DEVICE_INFO
/// of the driver its model names.
///
/// [onlySection] narrows it to one device block — the Devices tab asks about
/// the device on screen, where "every device in the room" would be a review of
/// tabs the reader is not looking at.
///
/// Two kinds of difference are deliberately NOT reported:
///
///   * a driver value that is blank against a room value that is not. Every
///     DEVICE_INFO leaves ip_address, password and serial_port empty because
///     they are site-specific, and "apply the defaults" must never be a way to
///     wipe the address of a device that is already commissioned.
///   * a key the schema hides for the block the change would produce — the
///     serial_port on a device the same driver puts on the network.
List<ModelDefaultMismatch> auditModelDefaults(
  AppStateProvider provider, {
  String? onlySection,
}) {
  final out = <ModelDefaultMismatch>[];

  provider.roomConfig.forEach((sectionKey, block) {
    if (onlySection != null && sectionKey != onlySection) return;
    if (block is! Map) return;
    if (provider.uiSchema.deviceTypeForSection(sectionKey) == null) return;
    final model = block['model']?.toString().trim() ?? '';
    if (model.isEmpty) return;
    final entry = provider.modelRegistry[model];
    if (entry == null) return;

    final preview = provider.previewModelSelection(sectionKey, model);
    if (!preview.known) return;

    final diffs = <ModelDefaultDiff>[];
    if (preview.moduleChanged) {
      diffs.add(ModelDefaultDiff(
        key: 'module',
        current: block['module'],
        fromModule: preview.newModule,
        connection: true,
      ));
    }
    for (final d in preview.diffs) {
      final proposed = d.moduleDefault;
      // Site-specific blank: the driver has nothing to say about this room's
      // address, so it must not be read as "clear it".
      final blankProposal = proposed == null || proposed.toString().isEmpty;
      final hasCurrent =
          d.current != null && d.current.toString().isNotEmpty;
      if (blankProposal && hasCurrent) continue;
      if (blankProposal && !hasCurrent) continue; // nothing to change
      diffs.add(ModelDefaultDiff(
        key: d.key,
        current: d.current,
        fromModule: proposed,
        connection: kConnectionDefaultKeys.contains(d.key),
      ));
    }
    if (diffs.isEmpty) return;

    diffs.sort((a, b) {
      // Connection first, then alphabetical: the reader is here for the port.
      if (a.connection != b.connection) return a.connection ? -1 : 1;
      return a.key.compareTo(b.key);
    });

    out.add(ModelDefaultMismatch(
      sectionKey: sectionKey,
      name: block['name']?.toString().trim().isNotEmpty == true
          ? block['name'].toString().trim()
          : sectionKey,
      model: model,
      module: preview.newModule,
      diffs: diffs,
    ));
  });

  out.sort((a, b) => a.sectionKey.compareTo(b.sectionKey));
  return out;
}
