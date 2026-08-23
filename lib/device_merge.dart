import 'av_device_library.dart';
import 'av_flow_model.dart';

/// ============================================================================
///  DEVICE CATALOG MERGE
/// ============================================================================
///  Two engineers keep two av_devices.json files. One has filled in the price
///  and part number for a switcher; the other has drawn its real connector
///  set and knows what it draws. Neither file is "the" file, so merging can't
///  be "theirs wins" or "mine wins" — it has to be per difference.
///
///  [diffCatalogs] compares the two entry by entry and FIELD by field, and
///  returns only what actually differs. Every difference carries its own
///  [DeviceFieldDiff.selected] flag; the merge dialog ticks them (one, a
///  device's worth, or all of them) and [applyMerge] copies exactly the ticked
///  values into your catalog. Nothing else is touched: a model you have and
///  they don't stays, and a field you filled in that they left blank is never
///  overwritten by their blank.
/// ============================================================================

/// The fields a merge can copy across, one checkbox each.
enum DeviceField {
  manufacturer,
  partNumber,
  category,
  rackUnits,
  clearance,
  cableLength,
  powerWatts,
  price,
  educationPrice,
  notes,
  ports,
}

const Map<DeviceField, String> kDeviceFieldLabels = {
  DeviceField.manufacturer: 'Manufacturer',
  DeviceField.partNumber: 'Part number',
  DeviceField.category: 'Category',
  DeviceField.rackUnits: 'Rack units',
  DeviceField.clearance: 'Rack clearance (U above / below)',
  DeviceField.cableLength: 'Cable length (ft)',
  DeviceField.powerWatts: 'Power (W)',
  DeviceField.price: 'Unit price (list)',
  DeviceField.educationPrice: 'Unit price (education)',
  DeviceField.notes: 'Notes',
  DeviceField.ports: 'Connectors',
};

/// One field of one model that the two catalogs disagree about.
class DeviceFieldDiff {
  final DeviceField field;

  /// What each side says, rendered for the dialog.
  final String mine;
  final String theirs;

  /// True when my side has nothing here at all — a blank, a zero, no
  /// connectors. Not a disagreement so much as a gap, and the duplicate merge
  /// ticks these by default: taking a price for a field I left empty loses
  /// nothing, while overwriting a figure I typed is a decision.
  final bool mineIsBlank;

  /// Ticked = copy [theirs] into my catalog on apply.
  bool selected;

  DeviceFieldDiff({
    required this.field,
    required this.mine,
    required this.theirs,
    this.mineIsBlank = false,
    this.selected = false,
  });

  String get label => kDeviceFieldLabels[field] ?? field.name;

  /// [base] with this field taken from [theirs].
  AvDeviceTemplate applyTo(AvDeviceTemplate base, AvDeviceTemplate theirs) {
    switch (field) {
      case DeviceField.manufacturer:
        return base.copyWith(manufacturer: theirs.manufacturer);
      case DeviceField.partNumber:
        return base.copyWith(partNumber: theirs.partNumber);
      case DeviceField.category:
        return base.copyWith(category: theirs.category);
      case DeviceField.rackUnits:
        return base.copyWith(rackUnits: theirs.rackUnits);
      case DeviceField.clearance:
        // One decision, because the two halves describe one requirement: an
        // amplifier wanting a rail either side is not two facts to tick.
        return base.copyWith(
          clearanceAboveU: theirs.clearanceAboveU,
          clearanceBelowU: theirs.clearanceBelowU,
        );
      case DeviceField.cableLength:
        return base.copyWith(cableLengthFt: theirs.cableLengthFt);
      case DeviceField.powerWatts:
        return base.copyWith(powerWatts: theirs.powerWatts);
      case DeviceField.price:
        return base.copyWith(price: theirs.price);
      case DeviceField.educationPrice:
        return base.copyWith(educationPrice: theirs.educationPrice);
      case DeviceField.notes:
        return base.copyWith(notes: theirs.notes);
      case DeviceField.ports:
        return base.copyWith(ports: theirs.ports);
    }
  }
}

/// One model's worth of differences.
class DeviceDiff {
  /// The model name as the other file spells it.
  final String model;
  final AvDeviceTemplate theirs;

  /// My entry, or null when this model is new to me.
  final AvDeviceTemplate? mine;

  /// Differing fields — empty for a model I don't have at all, where the
  /// whole entry is the single decision ([selected]).
  final List<DeviceFieldDiff> fields;

  /// Whole-entry tick, used for a model that is new to me.
  bool selected;

  DeviceDiff({
    required this.model,
    required this.theirs,
    required this.mine,
    required this.fields,
    this.selected = false,
  });

  bool get isNew => mine == null;

  /// True when applying would change anything for this model.
  bool get anySelected =>
      isNew ? selected : fields.any((f) => f.selected);

  bool get allSelected =>
      isNew ? selected : fields.isNotEmpty && fields.every((f) => f.selected);

  void setAll(bool value) {
    selected = value;
    for (final f in fields) {
      f.selected = value;
    }
  }

  /// How many decisions this row holds, for the "N of M selected" count.
  int get decisionCount => isNew ? 1 : fields.length;
  int get selectedCount =>
      isNew ? (selected ? 1 : 0) : fields.where((f) => f.selected).length;

  /// The entry to store, or null when nothing is ticked.
  AvDeviceTemplate? merged() {
    if (isNew) return selected ? theirs.copyWith(custom: true) : null;
    if (!anySelected) return null;
    var out = mine!;
    for (final f in fields) {
      if (f.selected) out = f.applyTo(out, theirs);
    }
    return out.copyWith(custom: true);
  }
}

/// Every difference between [mine] and [theirs], newest information first:
/// models I don't have at all, then models we both have but describe
/// differently. Models only I have are not differences — a merge adds and
/// updates, it never deletes.
List<DeviceDiff> diffCatalogs(AvDeviceLibrary mine, AvDeviceLibrary theirs) {
  final byKey = {
    for (final t in mine.all) AvDeviceLibrary.normalizeModel(t.model): t,
  };

  final added = <DeviceDiff>[];
  final changed = <DeviceDiff>[];

  for (final theirEntry in theirs.all) {
    final key = AvDeviceLibrary.normalizeModel(theirEntry.model);
    final myEntry = byKey[key];
    if (myEntry == null) {
      added.add(
        DeviceDiff(
          model: theirEntry.model,
          theirs: theirEntry,
          mine: null,
          fields: const [],
        ),
      );
      continue;
    }

    final fields = fieldDiffs(myEntry, theirEntry);
    if (fields.isEmpty) continue;
    changed.add(
      DeviceDiff(
        model: theirEntry.model,
        theirs: theirEntry,
        mine: myEntry,
        fields: fields,
      ),
    );
  }

  return [...added, ...changed];
}

/// A blank on their side is not a difference worth offering: an empty
/// manufacturer or a 0 price means "they never filled it in", and copying it
/// over something I did fill in would be a loss, not a merge.
List<DeviceFieldDiff> fieldDiffs(
  AvDeviceTemplate mine,
  AvDeviceTemplate theirs,
) {
  final out = <DeviceFieldDiff>[];

  void text(DeviceField field, String a, String b) {
    if (b.trim().isEmpty || a.trim() == b.trim()) return;
    out.add(
      DeviceFieldDiff(
        field: field,
        mine: a.trim().isEmpty ? '-' : a.trim(),
        theirs: b.trim(),
        mineIsBlank: a.trim().isEmpty,
      ),
    );
  }

  void number(DeviceField field, num a, num b, {int decimals = 0}) {
    if (b <= 0 || a == b) return;
    String show(num v) =>
        v <= 0 ? '-' : (decimals == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(decimals));
    out.add(
      DeviceFieldDiff(
        field: field,
        mine: show(a),
        theirs: show(b),
        mineIsBlank: a <= 0,
      ),
    );
  }

  text(DeviceField.manufacturer, mine.manufacturer, theirs.manufacturer);
  text(DeviceField.partNumber, mine.partNumber, theirs.partNumber);
  text(DeviceField.category, mine.category, theirs.category);
  number(DeviceField.rackUnits, mine.rackUnits, theirs.rackUnits);
  String clearance(AvDeviceTemplate t) =>
      t.clearanceAboveU == 0 && t.clearanceBelowU == 0
          ? '-'
          : '${t.clearanceAboveU} above / ${t.clearanceBelowU} below';
  if ((theirs.clearanceAboveU > 0 || theirs.clearanceBelowU > 0) &&
      (mine.clearanceAboveU != theirs.clearanceAboveU ||
          mine.clearanceBelowU != theirs.clearanceBelowU)) {
    out.add(DeviceFieldDiff(
      field: DeviceField.clearance,
      mine: clearance(mine),
      theirs: clearance(theirs),
      mineIsBlank: mine.clearanceAboveU == 0 && mine.clearanceBelowU == 0,
    ));
  }
  number(DeviceField.cableLength, mine.cableLengthFt, theirs.cableLengthFt);
  number(DeviceField.powerWatts, mine.powerWatts, theirs.powerWatts);
  number(DeviceField.price, mine.price, theirs.price, decimals: 2);
  // The second published price is its own decision, and its own checkbox: a
  // catalog merged without it used to arrive with list prices and no
  // education prices, which reads as "not on education pricing" rather than
  // as "nobody copied that column".
  number(
    DeviceField.educationPrice,
    mine.educationPrice,
    theirs.educationPrice,
    decimals: 2,
  );
  text(DeviceField.notes, mine.notes, theirs.notes);

  if (theirs.ports.isNotEmpty && !_samePorts(mine.ports, theirs.ports)) {
    out.add(
      DeviceFieldDiff(
        field: DeviceField.ports,
        mine: describePorts(mine.ports),
        theirs: describePorts(theirs.ports),
        mineIsBlank: mine.ports.isEmpty,
      ),
    );
  }
  return out;
}

/// Connector sets match when the same ids carry the same label, signal,
/// direction and side — order included, since the order is the box layout.
bool _samePorts(List<AvPort> a, List<AvPort> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id ||
        a[i].label != b[i].label ||
        a[i].signal != b[i].signal ||
        a[i].direction != b[i].direction ||
        a[i].side != b[i].side) {
      return false;
    }
  }
  return true;
}

/// "12 connectors (8 in / 4 out)" — enough to judge a port-list swap without
/// reading forty rows in a dialog.
String describePorts(List<AvPort> ports) {
  if (ports.isEmpty) return 'none';
  final ins = ports.where((p) => p.direction != PortDirection.output).length;
  final outs = ports.where((p) => p.direction != PortDirection.input).length;
  return '${ports.length} connectors ($ins in / $outs out)';
}

// ---------------------------------------------------------------------------
//  FOLDING TWO ENTRIES FOR THE SAME BOX INTO ONE
// ---------------------------------------------------------------------------
//  Same machinery, pointed inwards. A duplicate part number means one product
//  is in the catalog twice under two names, so the decision is the same one a
//  file merge makes — which side of each field to keep — with one extra: the
//  entries that lose are deleted rather than left beside the winner, because
//  leaving them is what produced the problem.

/// The decisions for folding [others] into [keeper]: one [DeviceDiff] per
/// entry to be merged away, holding only the fields where it says something
/// [keeper] does not already say.
///
/// Fields the keeper has nothing for arrive ticked, and fields where the two
/// disagree arrive unticked. That is the difference between filling a gap and
/// overwriting a figure somebody typed, and only the second one deserves a
/// decision.
List<DeviceDiff> duplicateDiffs(
  AvDeviceTemplate keeper,
  Iterable<AvDeviceTemplate> others,
) => [
  for (final other in others)
    DeviceDiff(
      model: other.model,
      theirs: other,
      mine: keeper,
      fields: [
        for (final f in fieldDiffs(keeper, other))
          DeviceFieldDiff(
            field: f.field,
            mine: f.mine,
            theirs: f.theirs,
            mineIsBlank: f.mineIsBlank,
            selected: f.mineIsBlank,
          ),
      ],
    ),
];

/// [keeper] with every ticked value in [others] folded in, newest decision
/// last — the single entry the group collapses to.
AvDeviceTemplate mergedDuplicate(
  AvDeviceTemplate keeper,
  List<DeviceDiff> others,
) {
  var out = keeper;
  for (final diff in others) {
    for (final field in diff.fields) {
      if (field.selected) out = field.applyTo(out, diff.theirs);
    }
  }
  return out;
}

/// Writes the folded entry into [library] and drops the models it absorbed.
/// Returns how many entries were removed.
///
/// The removed names are gone from the catalog, so a room that names one
/// falls back to generic connectors and no price — which is why the dialog
/// says which names are going before it does this, and why the keeper should
/// be the name the rooms actually use.
int applyDuplicateMerge(
  AvDeviceLibrary library,
  AvDeviceTemplate keeper,
  List<DeviceDiff> others,
) {
  library.upsert(mergedDuplicate(keeper, others));
  int removed = 0;
  for (final diff in others) {
    if (AvDeviceLibrary.normalizeModel(diff.model) ==
        AvDeviceLibrary.normalizeModel(keeper.model)) {
      continue; // never delete the entry being kept
    }
    library.remove(diff.model);
    removed++;
  }
  return removed;
}

/// Copies every ticked difference into [mine]. Returns how many models
/// changed.
int applyMerge(AvDeviceLibrary mine, List<DeviceDiff> diffs) {
  int applied = 0;
  for (final d in diffs) {
    final merged = d.merged();
    if (merged == null) continue;
    mine.upsert(merged);
    applied++;
  }
  return applied;
}
