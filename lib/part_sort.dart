import 'building_project.dart';
import 'project_estimate.dart';
import 'project_schedule.dart';

/// ============================================================================
///  READING THE PARTS LIST IN A DIFFERENT ORDER
/// ============================================================================
///  The master list is GROUPED - equipment, then rack hardware, then cabling,
///  then the rest - because that is the order somebody builds a job in, and it
///  is the right default. It is the wrong order for almost every question the
///  list actually gets asked:
///
///    * "what is holding this job up" is the list by lead time, longest first;
///    * "what do I have to buy this month" is the list by order-by date;
///    * "where is the money" is the list by extended price, biggest first;
///    * "did I get everything from Extron" is the list by vendor;
///    * "is this part on here twice" is the list by name.
///
///  So the columns sort. Pressing a heading sorts up it, pressing it again
///  sorts down it, and pressing it a third time puts the list back the way it
///  was built - because the grouped order carries information that no sort
///  reproduces, and a list somebody sorted once and could not un-sort is a list
///  that has quietly lost it.
///
///  NOTHING HERE IS STORED. The order is a way of LOOKING at the list, not a
///  fact about the job, and a project file that remembered somebody had sorted
///  it by price one afternoon would hand the next reader a document that is
///  subtly not the one that was issued.
///
///  BLANKS SORT LAST, WHICHEVER WAY THE ARROW POINTS. A part nobody has priced
///  and a part nobody has asked the vendor about are the rows most worth
///  finding, and either would spend half the time buried at the far end of the
///  list if it sorted as a zero. They are collected at the bottom instead,
///  where they read as a group of their own.
/// ============================================================================

/// What the list is ordered by.
enum PartSortKey {
  /// The order the estimate built it in: by kind, then by name.
  natural,
  part,
  qty,
  unit,
  extended,
  vendor,
  leadTime,
  orderBy,
}

/// What each heading is called, so the list and any menu of them agree.
const Map<PartSortKey, String> kPartSortLabels = {
  PartSortKey.natural: 'Grouped',
  PartSortKey.part: 'Part',
  PartSortKey.qty: 'Qty',
  PartSortKey.unit: 'Unit',
  PartSortKey.extended: 'Extended',
  PartSortKey.vendor: 'Vendor',
  PartSortKey.leadTime: 'Lead time',
  PartSortKey.orderBy: 'Order by',
};

/// The next state of a column heading that is pressed.
///
/// Up, then down, then back to the grouped order. Three states rather than two
/// because the grouped order is not just "sorted by something else" - see the
/// header of this file - and it has to be reachable from the heading somebody
/// pressed by accident.
({PartSortKey key, bool ascending}) nextPartSort({
  required PartSortKey current,
  required bool ascending,
  required PartSortKey pressed,
}) {
  if (pressed != current) return (key: pressed, ascending: true);
  if (ascending) return (key: pressed, ascending: false);
  return (key: PartSortKey.natural, ascending: true);
}

/// [lines] in the order [key] asks for. Never sorts in place: the estimate's
/// own list is shared, and re-ordering it under the panes that read it is how
/// a Rooms pane starts listing parts by price.
///
/// [project] supplies the lead times and deadlines the two schedule columns
/// are worked out from; [asOf] is passed through so a test can pin today.
List<MasterPartLine> sortMasterParts(
  List<MasterPartLine> lines, {
  required PartSortKey key,
  required bool ascending,
  required BuildingProject project,
  DateTime? asOf,
}) {
  if (key == PartSortKey.natural) return List.of(lines);

  /// The value a line sorts on, or null when it has none - see the header:
  /// null is not zero, and it goes to the bottom either way.
  Comparable<Object>? valueOf(MasterPartLine line) {
    switch (key) {
      case PartSortKey.natural:
        return null;
      case PartSortKey.part:
        return line.description.toLowerCase();
      case PartSortKey.qty:
        return line.qty;
      case PartSortKey.unit:
        // A part nobody could price is not a part that costs nothing.
        return line.unpriced ? null : line.unitPrice;
      case PartSortKey.extended:
        return line.unpriced ? null : line.total;
      case PartSortKey.vendor:
        // An untagged part is the one worth finding, so it is a blank rather
        // than an empty string that would sort first and look deliberate.
        final name = line.vendor?.name.trim() ?? '';
        return name.isEmpty ? null : name.toLowerCase();
      case PartSortKey.leadTime:
        final days = schedulePart(
          line: line,
          project: project,
          asOf: asOf,
        ).leadDays;
        return days?.toDouble();
      case PartSortKey.orderBy:
        final orderBy = schedulePart(
          line: line,
          project: project,
          asOf: asOf,
        ).orderBy;
        return orderBy?.millisecondsSinceEpoch.toDouble();
    }
  }

  // Worked out ONCE per line rather than on every comparison. A sort is
  // O(n log n) comparisons and the two schedule keys each rebuild a part's
  // dates, which on a two-hundred-part list is sixteen hundred rebuilds to
  // order one column.
  final keyed = [
    for (final line in lines) (line: line, value: valueOf(line)),
  ];

  keyed.sort((a, b) {
    if (a.value == null && b.value == null) {
      return a.line.description.toLowerCase().compareTo(
        b.line.description.toLowerCase(),
      );
    }
    // BLANKS LAST, WHICHEVER WAY THE ARROW POINTS. Not folded into the
    // comparison, because a null that sorted as a zero would flip to the top
    // the moment somebody reversed the column.
    if (a.value == null) return 1;
    if (b.value == null) return -1;
    final compared = a.value!.compareTo(b.value!);
    if (compared != 0) return ascending ? compared : -compared;
    // TIES BREAK BY NAME, IN NAME ORDER, whichever way the column points. A
    // list of forty parts that all cost the same should not shuffle itself
    // when somebody reverses it.
    return a.line.description.toLowerCase().compareTo(
      b.line.description.toLowerCase(),
    );
  });

  return [for (final k in keyed) k.line];
}
