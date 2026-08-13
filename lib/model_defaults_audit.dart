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

  /// The connection this comparison was made against ('Serial'), and every
  /// style the driver publishes a block for. The review offers the second so
  /// somebody can ask what the driver says about a connection the device is
  /// not on yet — the answer to "what would this look like over serial".
  final String comType;
  final List<String> availableComTypes;

  const ModelDefaultMismatch({
    required this.sectionKey,
    required this.name,
    required this.model,
    required this.module,
    required this.diffs,
    this.comType = '',
    this.availableComTypes = const [],
  });

  /// The keys ticked when the review opens.
  Set<String> get defaultSelection => {
    for (final d in diffs)
      if (d.connection) d.key,
  };
}

/// Every connection style any driver in scope publishes a block for, in the
/// order the com_type dropdown lists them.
///
/// Read off the DEVICES rather than off an audit result, so the picker still
/// offers Serial on a room whose blocks all agree with their drivers already —
/// "what would this look like over serial" is a question about a device, not
/// about a disagreement.
List<String> comparableComTypes(
  AppStateProvider provider, {
  String? onlySection,
}) {
  final found = <String>{};
  provider.roomConfig.forEach((sectionKey, block) {
    if (onlySection != null && sectionKey != onlySection) return;
    if (block is! Map) return;
    if (provider.uiSchema.deviceTypeForSection(sectionKey) == null) return;
    final model = block['model']?.toString().trim() ?? '';
    final module = provider.modelRegistry[model]?.module ??
        block['module']?.toString().trim() ??
        '';
    if (module.isEmpty) return;
    found.addAll(provider.comTypeStylesFor(module));
  });
  final order = kComTypeStyleLabels.values.toList();
  return [
    for (final label in order)
      if (found.contains(label)) label,
  ];
}

/// The label the review's connection picker uses for the pre-conversion file,
/// and the [ModelDefaultMismatch.comType] the original-file comparison carries.
///
/// Not a connection style — it is the fifth thing the same review can be asked
/// to compare a block against, and it is spelled in a way no com_type ever will
/// be so the two can never be confused for one another.
const String kOriginalFileComparison = 'Original File';

/// What the room said BEFORE the conversion touched it, per device block.
///
/// The driver comparison answers "what does the python module say this model
/// wants". This answers the other question a converted room raises — "what did
/// the file I opened actually have here" — for the case the conversion got
/// wrong: a port the site had changed on purpose, a name somebody had agreed, a
/// baud rate the family default overwrote.
///
/// Reported on the same terms as the driver comparison, and applied through the
/// same tick boxes, so putting one value back is one click rather than a trip
/// through the raw editor.
///
/// Nothing is ticked by default. A converted value is usually the right one —
/// that is why the conversion exists — so this is a list to read, not a list to
/// accept.
///
/// Two kinds of difference are left out, for the same reasons the driver
/// comparison leaves them out: a key the original did not carry at all (the
/// conversion ADDING a property is what it is for), and a key the schema hides
/// for this block.
List<ModelDefaultMismatch> auditOriginalFile(
  AppStateProvider provider, {
  String? onlySection,
}) {
  final out = <ModelDefaultMismatch>[];
  if (provider.originalLoadedConfig.isEmpty) return out;

  provider.roomConfig.forEach((sectionKey, block) {
    if (onlySection != null && sectionKey != onlySection) return;
    if (block is! Map) return;
    if (provider.uiSchema.deviceTypeForSection(sectionKey) == null) return;
    final original = provider.originalBlockFor(sectionKey);
    if (original == null) return;

    // Lined up on the comparison spelling the key mapper itself uses, so a
    // legacy COMTYPE is recognized as the com_type it became rather than
    // reported as a property the conversion invented.
    String norm(String s) => s.toLowerCase().replaceAll('_', '');
    final byNorm = <String, dynamic>{
      for (final e in original.entries) norm(e.key): e.value,
    };

    final diffs = <ModelDefaultDiff>[];
    block.forEach((rawKey, current) {
      final key = rawKey.toString();
      if (!byNorm.containsKey(norm(key))) return; // the conversion added it
      final before = byNorm[norm(key)];
      if (before is Map || before is List) return; // not a field on the form
      if (provider.uiSchema.isHiddenFor(
        key,
        {for (final e in block.entries) e.key.toString(): e.value},
        sectionKey: sectionKey,
      )) {
        return;
      }
      if (before?.toString() == current?.toString()) return;
      diffs.add(ModelDefaultDiff(
        key: key,
        current: current,
        fromModule: before,
        // Never ticked: see above — the conversion's answer is the one to
        // keep unless a human decides otherwise.
        connection: false,
      ));
    });
    if (diffs.isEmpty) return;
    diffs.sort((a, b) => a.key.compareTo(b.key));

    out.add(ModelDefaultMismatch(
      sectionKey: sectionKey,
      name: block['name']?.toString().trim().isNotEmpty == true
          ? block['name'].toString().trim()
          : sectionKey,
      model: block['model']?.toString().trim() ?? '',
      module: block['module']?.toString().trim() ?? '',
      diffs: diffs,
      comType: kOriginalFileComparison,
    ));
  });

  out.sort((a, b) => a.sectionKey.compareTo(b.sectionKey));
  return out;
}

/// Every device in the loaded room whose block disagrees with the DEVICE_INFO
/// of the driver its model names.
///
/// [onlySection] narrows it to one device block — the Devices tab asks about
/// the device on screen, where "every device in the room" would be a review of
/// tabs the reader is not looking at.
///
/// [comType] asks what the driver says about ONE connection style. Left null,
/// each device is compared against the block for the connection IT IS ON,
/// which is the question somebody opening the review is actually asking — a
/// device on a COM port compared against the network block is offered a
/// net_port and a protocol it has no use for, and told nothing about its baud
/// rate. Set it to look at another connection before committing to it.
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
  String? comType,
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

    // The connection this device is ON, unless the reader asked about another
    // one. Without this a serial device is reviewed against the network block,
    // which is every wrong key and none of the right ones.
    final against = comType ?? block['com_type']?.toString() ?? '';
    final preview = provider.previewModelSelection(sectionKey, model,
        comType: against.isEmpty ? null : against);
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
    final styles = provider.comTypeStylesFor(preview.newModule);
    if (diffs.isEmpty) {
      // Nothing to change on THIS connection. When one device was asked about
      // by name, the review still opens if the driver has something to say
      // about a connection it is not on — that is the whole point of the
      // picker, and it cannot be reached through a dialog that never opens.
      // A whole-file review after a conversion keeps its old manners and stays
      // shut when the room already agrees with its drivers.
      if (onlySection == null || comType != null || styles.length < 2) return;
      out.add(ModelDefaultMismatch(
        sectionKey: sectionKey,
        name: block['name']?.toString().trim().isNotEmpty == true
            ? block['name'].toString().trim()
            : sectionKey,
        model: model,
        module: preview.newModule,
        diffs: const [],
        comType: against,
        availableComTypes: styles,
      ));
      return;
    }

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
      comType: against,
      availableComTypes: styles,
    ));
  });

  out.sort((a, b) => a.sectionKey.compareTo(b.sectionKey));
  return out;
}
