import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';

/// The shipped av_devices.json is generated from the Extron engineering
/// drawing stencils in drawings_library/. It is the file every room's ports,
/// rack heights and prices start from, so a malformed or half-read entry in it
/// is a defect in every room at once.
void main() {
  late AvDeviceLibrary catalog;

  setUpAll(() async {
    catalog = await AvDeviceLibrary.readFile('av_devices.json');
  });

  test('the whole catalog parses', () {
    expect(catalog.modelCount, greaterThan(900));
    for (final entry in catalog.all) {
      expect(entry.model.trim(), isNotEmpty);
      expect(entry.custom, isTrue, reason: 'a file entry is the user\'s');
    }
  });

  test('every powered device carries exactly one power inlet', () {
    int mains = 0, poe = 0, passive = 0;
    // poe is asserted on below; the count is reported for the reader.
    for (final entry in catalog.all) {
      final inlets = entry.ports.where((p) => p.isPowerInlet).toList();
      switch (entry.powerInput) {
        case PowerInput.none:
          passive++;
          expect(inlets, isEmpty, reason: '${entry.model} is passive');
        case PowerInput.poe:
          poe++;
          expect(inlets.length, 1, reason: '${entry.model} needs one inlet');
          expect(inlets.single.label, contains('PoE'));
        case PowerInput.mains:
          mains++;
          expect(inlets.length, 1, reason: '${entry.model} needs one inlet');
          expect(inlets.single.id, kPowerPortId);
      }
    }
    expect(mains, greaterThan(700));
    expect(passive, greaterThan(0));
    expect(mains + poe + passive, catalog.modelCount);
  });

  test('the inlet is kept out of the signal connector counts', () {
    final switcher = catalog.templateForModel('SW4 HD 4K PLUS')!;
    expect(switcher.ports.any((p) => p.isPowerInlet), isTrue);
    // Four HDMI in; the POWER inlet and the RS-232 port are not HDMI inputs.
    expect(
      switcher.ports.where((p) => p.signal == SignalType.hdmi).length,
      5,
    );
    expect(
      switcher.inputCount,
      switcher.ports.where((p) => !p.isPowerInlet && !p.isOutput).length,
    );
  });

  test('models the app already knew keep their rack height', () {
    expect(
      catalog.templateForModel('DTP CrossPoint 108 4K IPCP MA 70')?.rackUnits,
      3,
    );
    expect(catalog.templateForModel('DMP 128 Plus C AT')?.rackUnits, 1);
  });

  test('drawings supply the part number, description and connectors', () {
    final dsp = catalog.templateForModel('DMP 128 Plus C AT')!;
    expect(dsp.manufacturer, 'Extron');
    expect(dsp.partNumber, isNotEmpty);
    expect(dsp.category, 'Audio');
    expect(dsp.notes, contains('ProDSP'));
    expect(
      dsp.ports.where((p) => p.signal == SignalType.micLine).length,
      greaterThanOrEqualTo(12),
    );
    expect(dsp.ports.any((p) => p.signal == SignalType.dante), isTrue);
  });

  test('inputs land on the left and outputs on the right', () {
    for (final entry in catalog.all) {
      for (final port in entry.ports) {
        if (port.isPowerInlet) continue;
        expect(
          port.side,
          port.isOutput ? PortSide.right : PortSide.left,
          reason: '${entry.model} / ${port.label}',
        );
      }
    }
  });

  test('port ids are unique within a device', () {
    for (final entry in catalog.all) {
      final ids = entry.ports.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length, reason: entry.model);
    }
  });

  test('a metered entry says where the figure came from', () {
    // The drawings carry no wattage, so for a long time nothing here was
    // metered at all. Some entries are now — the projectors, off their
    // manufacturer spec pages (tools/import_projectorcentral.py) — which
    // makes the blanket "nothing is metered" check the wrong guard. The
    // point it was making still stands: a fabricated figure is worse than a
    // blank one, because a blank is reported as missing and a number is
    // believed. So the rule is provenance — a wattage must have a page
    // behind it.
    final metered = catalog.all.where((e) => e.powerWatts > 0).toList();
    for (final entry in metered) {
      expect(entry.url.trim(), isNotEmpty,
          reason: '${entry.model} has a wattage but no source page');
      expect(entry.powerWatts, lessThan(20000),
          reason: '${entry.model}: that is a parse error, not a projector');
    }

    // And most of the catalog is still blank, because no source covers it.
    final unmetered = catalog.all.where((e) => e.powerWatts == 0).length;
    expect(unmetered, greaterThan(metered.length),
        reason: 'a catalog with no gaps means something was invented');
  });

  test('prices came from a price list, and only where one matched', () {
    // MSRP is imported from a published EXTRON price list, matched on Extron
    // part number (tools/import_price_list.py — its PART_RE only recognises
    // the 60-1234-01 form). It is not read off the drawings and not guessed.
    //
    // So the rule is about the entries that importer could have touched:
    //
    //   1. an Extron entry with a price has the part number it was matched on
    //      — a price with nothing behind it means the import went wrong;
    //   2. plenty of entries are still unpriced, because no price list covers
    //      the whole catalog and the importer leaves non-matches alone;
    //   3. and however a price arrived, it has to be a plausible figure.
    //
    // Third-party gear is deliberately outside rule 1. An Extron price list
    // will never carry an APC PDU or a Panasonic projector, so those entries
    // have no Extron part number and never will; a price on one is somebody's
    // own figure, and demanding a part number there would only be satisfied by
    // inventing one.
    final priced = catalog.all.where((e) => e.price > 0).toList();
    expect(priced, isNotEmpty, reason: 'the shipped catalog carries MSRPs');

    for (final entry in priced) {
      if (entry.manufacturer.trim().toLowerCase() == 'extron') {
        expect(entry.partNumber.trim(), isNotEmpty,
            reason: '${entry.model} is priced but has no part number');
      }
      expect(entry.price, lessThan(1000000),
          reason: '${entry.model}: a six-figure list price is a parse error');
    }

    // And the EXTRON half is still priced BY the importer rather than by hand.
    //
    // Scoped to Extron on purpose. This used to count the whole catalog and
    // allow twenty hand-priced entries, which held only while third-party gear
    // was a handful of PDUs; a manufacturer's own price list imported whole
    // (Panasonic's Top of the Class list is 138 entries) is exactly the thing
    // rule 1's carve-out above permits, and counting those made the guard fire
    // on the legitimate case while saying nothing about the Extron importer it
    // was written to watch.
    final extron = priced
        .where((e) => e.manufacturer.trim().toLowerCase() == 'extron')
        .toList();
    expect(extron, isNotEmpty);
    expect(extron.where((e) => e.partNumber.trim().isEmpty), isEmpty,
        reason: 'every Extron price should have come off the price list');

    // A price the Extron importer did not set has to say whose gear it is, or
    // there is no way back to the list it was read off.
    for (final entry in priced.where((e) => e.partNumber.trim().isEmpty)) {
      expect(entry.manufacturer.trim(), isNotEmpty,
          reason: '${entry.model}: a hand-entered price with no manufacturer '
              'cannot be traced to any price list');
    }

    final unpriced = catalog.all.where((e) => e.price == 0).length;
    expect(unpriced, greaterThan(0),
        reason: 'a catalog with no gaps means something was invented');
  });

  test('education prices, where set, are below list', () {
    // The second tier is a discount off MSRP. One above list is a typo or a
    // swapped column, and it would quietly overcharge every education quote.
    for (final entry in catalog.all) {
      if (entry.educationPrice <= 0) continue;
      expect(entry.price, greaterThan(0),
          reason: '${entry.model} has an education price but no MSRP');
      expect(entry.educationPrice, lessThanOrEqualTo(entry.price),
          reason: '${entry.model}: education price above list');
    }
  });

  test('the file is the one the app would load from the root folder', () {
    expect(File('av_devices.json').existsSync(), isTrue);
  });
}
