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
  powerWatts,
  price,
  notes,
  ports,
}

const Map<DeviceField, String> kDeviceFieldLabels = {
  DeviceField.manufacturer: 'Manufacturer',
  DeviceField.partNumber: 'Part number',
  DeviceField.category: 'Category',
  DeviceField.rackUnits: 'Rack units',
  DeviceField.powerWatts: 'Power (W)',
  DeviceField.price: 'Unit price',
  DeviceField.notes: 'Notes',
  DeviceField.ports: 'Connectors',
};

/// One field of one model that the two catalogs disagree about.
class DeviceFieldDiff {
  final DeviceField field;

  /// What each side says, rendered for the dialog.
  final String mine;
  final String theirs;

  /// Ticked = copy [theirs] into my catalog on apply.
  bool selected;

  DeviceFieldDiff({
    required this.field,
    required this.mine,
    required this.theirs,
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
      case DeviceField.powerWatts:
        return base.copyWith(powerWatts: theirs.powerWatts);
      case DeviceField.price:
        return base.copyWith(price: theirs.price);
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

    final fields = _fieldDiffs(myEntry, theirEntry);
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
List<DeviceFieldDiff> _fieldDiffs(
  AvDeviceTemplate mine,
  AvDeviceTemplate theirs,
) {
  final out = <DeviceFieldDiff>[];

  void text(DeviceField field, String a, String b) {
    if (b.trim().isEmpty || a.trim() == b.trim()) return;
    out.add(
      DeviceFieldDiff(
        field: field,
        mine: a.trim().isEmpty ? '—' : a.trim(),
        theirs: b.trim(),
      ),
    );
  }

  void number(DeviceField field, num a, num b, {int decimals = 0}) {
    if (b <= 0 || a == b) return;
    String show(num v) =>
        v <= 0 ? '—' : (decimals == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(decimals));
    out.add(
      DeviceFieldDiff(field: field, mine: show(a), theirs: show(b)),
    );
  }

  text(DeviceField.manufacturer, mine.manufacturer, theirs.manufacturer);
  text(DeviceField.partNumber, mine.partNumber, theirs.partNumber);
  text(DeviceField.category, mine.category, theirs.category);
  number(DeviceField.rackUnits, mine.rackUnits, theirs.rackUnits);
  number(DeviceField.powerWatts, mine.powerWatts, theirs.powerWatts);
  number(DeviceField.price, mine.price, theirs.price, decimals: 2);
  text(DeviceField.notes, mine.notes, theirs.notes);

  if (theirs.ports.isNotEmpty && !_samePorts(mine.ports, theirs.ports)) {
    out.add(
      DeviceFieldDiff(
        field: DeviceField.ports,
        mine: describePorts(mine.ports),
        theirs: describePorts(theirs.ports),
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
