import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';

/// A PO NUMBER RETYPED IS A PO NUMBER EVENTUALLY MISTYPED.
///
/// The number is what everything else points at - the parts, the deliveries,
/// the vendor - so a "which PO?" box has to offer every one the job already
/// mentions rather than leave somebody reading it off another screen. What was
/// missing was the VENDORS: marking a vendor ordered raises the PO row too, but
/// a row that was later renumbered or deleted, or a number typed straight onto
/// a vendor, leaves the vendor holding the only copy.
void main() {
  BuildingProject job() => BuildingProject(name: 'Bessey', building: 'BSS');

  group('every number the job mentions', () {
    test('a PO row is on the list', () {
      final p = job()..addPo(number: 'PO-1188');
      expect(p.poNumbersInUse, contains('PO-1188'));
    });

    test('a number that only a package holds is on it too', () {
      final p = job();
      p.rfqs.add(
        const ProjectRfq(
          id: 'v1',
          title: 'Epson Direct',
          poNumber: 'PO-2044',
        ),
      );
      expect(
        p.poNumbersInUse,
        contains('PO-2044'),
        reason: 'whoever is logging the delivery is reading that number off '
            'the vendor\'s card',
      );
    });

    test('the same number twice is one entry', () {
      final p = job()..addPo(number: 'PO-1188');
      p.rfqs.add(
        const ProjectRfq(
          id: 'v1',
          title: 'Epson Direct',
          poNumber: 'PO-1188',
        ),
      );
      expect(
        p.poNumbersInUse
            .where((n) => normalizePoNumber(n) == 'PO-1188')
            .length,
        1,
      );
    });

    test('a blank number is not a number', () {
      final p = job();
      p.rfqs.add(
        const ProjectRfq(id: 'v1', title: 'Epson Direct', poNumber: '   '),
      );
      expect(p.poNumbersInUse, isEmpty);
    });

    test('the spelling it was first seen in is the one offered', () {
      // The rows come first, so a PO row's own spelling wins over a vendor's.
      // Matching is case-insensitive and nothing more - 'po 1188' with a space
      // where the hyphen was is a DIFFERENT number, and quietly folding the
      // two together would hide somebody's typo rather than show it.
      final p = job()..addPo(number: 'PO-1188');
      p.rfqs.add(
        const ProjectRfq(id: 'v1', title: 'Epson Direct', poNumber: 'po-1188'),
      );
      expect(p.poNumbersInUse, ['PO-1188']);
    });

    test('a number the job knows with no row for it is findable', () {
      // What the "Add a purchase order" box offers: until a row exists there
      // is nothing to attach the order to and nothing to tick equipment onto.
      final p = job();
      p.rfqs.add(
        const ProjectRfq(
          id: 'v1',
          title: 'Epson Direct',
          poNumber: 'PO-2044',
        ),
      );
      p.addPo(number: 'PO-1188');

      final loose = [
        for (final n in p.poNumbersInUse)
          if (p.poByNumber(n) == null) n,
      ];
      expect(loose, ['PO-2044']);
    });
  });
}
