import 'dart:convert';

import 'package:extron_configurator/building_project.dart';
import 'package:flutter_test/flutter_test.dart';

BuildingProject _roundTrip(BuildingProject p) => BuildingProject.fromJson(
  jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>,
);

void main() {
  test('walkthroughs survive a save and load', () {
    final p = BuildingProject(name: 'Bessey', building: 'BSS');
    p.walkthroughs.add(
      ProjectWalkthrough(
        id: 'walk1',
        date: DateTime(2026, 11, 3),
        by: 'Sam',
        notes: 'Racks in, ceiling open',
      ),
    );
    final back = _roundTrip(p);
    expect(back.walkthroughs, hasLength(1));
    expect(back.walkthroughs.single.date, DateTime(2026, 11, 3));
    expect(back.walkthroughs.single.by, 'Sam');
    expect(back.walkthroughs.single.notes, 'Racks in, ceiling open');
  });

  test('an order keeps installed and without-a-quote', () {
    final p = BuildingProject(name: 'Bessey', building: 'BSS');
    p.setPartOrder(
      'equipment|abc',
      PartOrder(
        orderedOn: DateTime(2026, 10, 1),
        withoutQuote: true,
        installedOn: DateTime(2026, 11, 2),
      ),
    );
    final order = _roundTrip(p).orderForPart('equipment|abc')!;
    expect(order.isOrdered, isTrue);
    expect(order.withoutQuote, isTrue);
    expect(order.installedOn, DateTime(2026, 11, 2));
  });

  test('installed alone is worth keeping', () {
    final p = BuildingProject(name: 'Bessey', building: 'BSS');
    p.setPartOrder('k', PartOrder(installedOn: DateTime(2026, 11, 2)));
    expect(p.orderForPart('k')?.isInstalled, isTrue);
    expect(p.orderForPart('k')?.isOrdered, isFalse);
  });

  test('procurement column choices survive a save and load', () {
    final p = BuildingProject(name: 'Bessey', building: 'BSS');
    p.procurementColumnChoices['phase'] = ['Before drywall', 'After paint'];
    expect(
      _roundTrip(p).procurementColumnChoices['phase'],
      ['Before drywall', 'After paint'],
    );
  });
}
