import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/device_merge.dart';
import 'package:extron_configurator/projection_calc.dart';

/// A projector's published specs: kept with the catalog, offered by a
/// merge, and the lens shift handed to the projection calculator.
void main() {
  const projector = AvDeviceTemplate(
    model: 'PowerLite L630U',
    manufacturer: 'Epson',
    category: 'Projector',
    throwRatioMin: 1.35,
    throwRatioMax: 2.2,
    lumens: 6200,
    resolution: '1920x1200',
    aspectRatio: '16:10',
    contrastRatio: '2,500,000:1',
    lightSource: 'Laser Phosphor',
    lightLifeHours: 20000,
    zoomRatio: 1.6,
    lensShiftUp: 50,
    lensShiftDown: 50,
    lensShiftSide: 20,
    weightLbs: 18.5,
    noiseDb: 38,
    ports: [],
  );

  test('the specs round-trip through the catalog file', () {
    final back = AvDeviceTemplate.fromJson(projector.toJson());
    expect(back.resolution, '1920x1200');
    expect(back.aspectRatio, '16:10');
    expect(back.contrastRatio, '2,500,000:1');
    expect(back.lightSource, 'Laser Phosphor');
    expect(back.lightLifeHours, 20000);
    expect(back.zoomRatio, 1.6);
    expect(back.lensShiftUp, 50);
    expect(back.lensShiftDown, 50);
    expect(back.lensShiftSide, 20);
    expect(back.weightLbs, 18.5);
    expect(back.noiseDb, 38);
  });

  test('a blank spec is not written', () {
    const bare = AvDeviceTemplate(model: 'X', ports: []);
    final json = bare.toJson();
    for (final key in ['resolution', 'contrastRatio', 'lensShiftUp', 'noiseDb']) {
      expect(json.containsKey(key), isFalse, reason: key);
    }
  });

  test('a merge offers the specs as one field, and copies them', () {
    const mine = AvDeviceTemplate(
      model: 'PowerLite L630U',
      category: 'Projector',
      ports: [],
    );
    final diffs = fieldDiffs(mine, projector);
    final specs = diffs.singleWhere((d) => d.field == DeviceField.projectorSpecs);
    expect(specs.mineIsBlank, isTrue);
    expect(specs.theirs, contains('1920x1200'));
    final merged = specs.applyTo(mine, projector);
    expect(merged.lensShiftSide, 20);
    expect(merged.weightLbs, 18.5);
  });

  test('the calculator gets the lens shift, even with a lens bought', () {
    final own = projectorSpecsOf(projector)!;
    expect((own.shiftUp, own.shiftDown, own.shiftSide), (50, 50, 20));

    const lens = AvDeviceTemplate(
      model: 'ELPLM15 lens',
      category: 'Projector Lens',
      throwRatioMin: 3,
      throwRatioMax: 5,
      ports: [],
    );
    final choices = projectorSpecChoices([projector], [lens]);
    expect(choices.last.source, 'ELPLM15 lens');
    expect(choices.last.shiftUp, 50);
  });
}
