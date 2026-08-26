import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/part_sort.dart';
import 'package:extron_configurator/project_estimate.dart';

/// READING THE PARTS LIST IN A DIFFERENT ORDER.
///
/// The failure these guard is the quiet one: a sort that buries the rows most
/// worth finding. A part nobody priced and a part nobody asked the vendor about
/// are the two the list exists to surface, and either would spend half its life
/// at the far end of the list if it sorted as a zero.
void main() {
  MasterPartLine part(
    String description, {
    double qty = 2,
    double unit = 50,
    bool unpriced = false,
    int? catalogLead,
    ProjectVendor? vendor,
  }) {
    final key = masterPartKey(
      kind: 'equipment',
      model: description,
      description: description,
    );
    return MasterPartLine(
      key: key,
      kind: MasterPartKind.equipment,
      description: description,
      model: description,
      partNumber: '',
      manufacturer: '',
      category: '',
      qty: qty,
      total: qty * unit,
      unitPrice: unit,
      maxUnitPrice: unit,
      qtyByRoom: const {},
      vendor: vendor,
      tagSource:
          vendor == null ? VendorTagSource.none : VendorTagSource.pinned,
      unpriced: unpriced,
      catalogLeadDays: catalogLead,
    );
  }

  List<String> namesOf(
    List<MasterPartLine> lines, {
    required PartSortKey key,
    bool ascending = true,
    BuildingProject? project,
  }) => [
    for (final l in sortMasterParts(
      lines,
      key: key,
      ascending: ascending,
      project: project ?? BuildingProject(),
      asOf: DateTime(2026, 1, 1),
    ))
      l.description,
  ];

  group('pressing a heading', () {
    test('sorts up it, then down it, then puts the list back', () {
      var state = nextPartSort(
        current: PartSortKey.natural,
        ascending: true,
        pressed: PartSortKey.leadTime,
      );
      expect(state, (key: PartSortKey.leadTime, ascending: true));

      state = nextPartSort(
        current: state.key,
        ascending: state.ascending,
        pressed: PartSortKey.leadTime,
      );
      expect(state, (key: PartSortKey.leadTime, ascending: false));

      // THE GROUPED ORDER HAS TO BE REACHABLE. It carries information no sort
      // reproduces, and a list somebody sorted by accident and could not
      // un-sort is a list that has quietly lost it.
      state = nextPartSort(
        current: state.key,
        ascending: state.ascending,
        pressed: PartSortKey.leadTime,
      );
      expect(state, (key: PartSortKey.natural, ascending: true));
    });

    test('a different heading starts that column at the top', () {
      expect(
        nextPartSort(
          current: PartSortKey.leadTime,
          ascending: false,
          pressed: PartSortKey.qty,
        ),
        (key: PartSortKey.qty, ascending: true),
      );
    });
  });

  group('the order itself', () {
    test('grouped leaves the list exactly as the estimate built it', () {
      final lines = [part('Screen'), part('Amp'), part('Mount')];
      expect(
        namesOf(lines, key: PartSortKey.natural),
        ['Screen', 'Amp', 'Mount'],
      );
    });

    test('sorting never re-orders the list it was handed', () {
      // The estimate's master list is shared with every other pane. Sorting it
      // in place is how the Rooms pane starts listing parts by price.
      final lines = [part('Screen'), part('Amp')];
      sortMasterParts(
        lines,
        key: PartSortKey.part,
        ascending: true,
        project: BuildingProject(),
      );
      expect(lines.map((l) => l.description), ['Screen', 'Amp']);
    });

    test('by name, by quantity and by money', () {
      final lines = [
        part('Screen', qty: 1, unit: 900),
        part('Amp', qty: 9, unit: 100),
        part('Mount', qty: 4, unit: 25),
      ];
      expect(
        namesOf(lines, key: PartSortKey.part),
        ['Amp', 'Mount', 'Screen'],
      );
      expect(
        namesOf(lines, key: PartSortKey.qty),
        ['Screen', 'Mount', 'Amp'],
      );
      expect(
        namesOf(lines, key: PartSortKey.unit, ascending: false),
        ['Screen', 'Amp', 'Mount'],
      );
      // Where the money is: nine amps at a hundred beats one screen at 900.
      expect(
        namesOf(lines, key: PartSortKey.extended, ascending: false),
        ['Amp', 'Screen', 'Mount'],
      );
    });

    test('a part nobody priced is not a part that costs nothing', () {
      final lines = [
        part('Screen', unit: 900),
        part('Unknown bracket', unit: 0, unpriced: true),
        part('Amp', unit: 100),
      ];
      // Cheapest first, and the blank is still at the bottom rather than
      // heading the list as a zero.
      expect(
        namesOf(lines, key: PartSortKey.unit),
        ['Amp', 'Screen', 'Unknown bracket'],
      );
      // ...and it stays at the bottom when the arrow flips.
      expect(
        namesOf(lines, key: PartSortKey.unit, ascending: false),
        ['Screen', 'Amp', 'Unknown bracket'],
      );
    });

    test('by lead time, with the ones nobody has asked about last', () {
      final quick = part('Amp', catalogLead: 7);
      final slow = part('Screen', catalogLead: 84);
      final unknown = part('Mount');
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 6, 1),
        // The JOB's figure beats the catalog's, which is the whole point of
        // being able to sort by it: this is the column that says what has
        // actually been chased.
        partLeadTimes: {quick.key: 120},
      );

      expect(
        namesOf(
          [quick, slow, unknown],
          key: PartSortKey.leadTime,
          ascending: false,
          project: project,
        ),
        ['Amp', 'Screen', 'Mount'],
      );
      expect(
        namesOf(
          [quick, slow, unknown],
          key: PartSortKey.leadTime,
          project: project,
        ),
        ['Screen', 'Amp', 'Mount'],
      );
    });

    test('by order-by date, soonest first', () {
      final slow = part('Screen', catalogLead: 84);
      final quick = part('Amp', catalogLead: 7);
      final noDate = part('Mount');
      final project = BuildingProject(deliveryDeadline: DateTime(2026, 6, 1));

      // The longest lead time has to be bought first - which is the whole
      // reason this column is worth sorting by rather than reading down.
      expect(
        namesOf(
          [quick, slow, noDate],
          key: PartSortKey.orderBy,
          project: project,
        ),
        ['Screen', 'Amp', 'Mount'],
      );
    });

    test('by vendor, with the untagged parts collected at the end', () {
      const extron = ProjectVendor(id: 'vendor1', name: 'Extron');
      const shure = ProjectVendor(id: 'vendor2', name: 'Shure');
      final lines = [
        part('Mic', vendor: shure),
        part('Bracket'),
        part('Switcher', vendor: extron),
      ];
      expect(
        namesOf(lines, key: PartSortKey.vendor),
        ['Switcher', 'Mic', 'Bracket'],
      );
      // An untagged part is the one worth finding, so it does not lead the
      // list just because a blank sorts before a letter.
      expect(
        namesOf(lines, key: PartSortKey.vendor, ascending: false),
        ['Mic', 'Switcher', 'Bracket'],
      );
    });

    test('ties break by name, the same way whichever way the arrow points', () {
      final lines = [
        part('Screen', unit: 100),
        part('Amp', unit: 100),
        part('Mount', unit: 100),
      ];
      // Forty parts that all cost the same should not shuffle when somebody
      // reverses the column.
      expect(
        namesOf(lines, key: PartSortKey.unit),
        ['Amp', 'Mount', 'Screen'],
      );
      expect(
        namesOf(lines, key: PartSortKey.unit, ascending: false),
        ['Amp', 'Mount', 'Screen'],
      );
    });
  });
}
