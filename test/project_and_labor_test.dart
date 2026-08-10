import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/export_tools.dart';
import 'package:extron_configurator/labor_rates.dart';

/// Labour on the estimate, the model search, and Save All — the parts where
/// losing work or quietly mis-costing a job is the failure mode.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('project_test_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppStateProvider room({String name = 'Bessey 103'}) {
    final provider = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {
          'gui_full_room_name': name,
          'gve_bldg': 'BSS',
          'gve_room': '103',
        },
      };
    provider.loadAvFlowForCurrentConfig();
    provider.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(
        const AvDeviceTemplate(
          model: 'DTP CrossPoint 108 4K IPCP MA 70',
          manufacturer: 'Extron',
          partNumber: '60-1381-23',
          rackUnits: 3,
          price: 8500,
          powerWatts: 90,
          ports: [],
        ),
      )
      ..upsert(
        const AvDeviceTemplate(
          model: 'SW4 HD 4K PLUS',
          manufacturer: 'Extron',
          price: 900,
          ports: [],
        ),
      );
    return provider;
  }

  group('labor', () {
    test('costs as rate x techs x hours', () {
      final provider = room();
      provider.laborRates = LaborRateBook.builtIn()
        ..upsert(
          const LaborRate(id: 'cts3', name: 'CTS III', hourlyRate: 95),
        );
      final line = provider.addAvCostLabor(rateId: 'cts3', techs: 2);
      provider.updateAvCostLabor(line.copyWith(hours: 24));

      final estimate = computeRoomCost(
        model: buildAvFlowModel(provider),
        library: provider.avDeviceLibrary,
        settings: provider.avCost,
        rates: provider.laborRates,
      );

      // Two techs for 24 hours each at $95.
      expect(estimate.labor.single.totalHours, 48);
      expect(estimate.laborTotal, 4560);
      expect(estimate.laborHours, 48);
      expect(estimate.subtotal, 4560);
    });

    test('hours with no rate behind them are reported, not costed at zero', () {
      final provider = room();
      // The shipped FMS role is a placeholder with no rate — exactly the case
      // that must not quietly price a day of facilities work at nothing.
      final line = provider.addAvCostLabor(rateId: 'fms', techs: 1);
      provider.updateAvCostLabor(line.copyWith(hours: 8));

      final estimate = computeRoomCost(
        model: buildAvFlowModel(provider),
        library: provider.avDeviceLibrary,
        settings: provider.avCost,
        rates: provider.laborRates,
      );
      expect(estimate.unratedLabor, 1);
      expect(estimate.isComplete, isFalse);
      expect(estimate.laborTotal, 0);

      final totals = costReportSections(
        estimate,
      ).firstWhere((s) => s.title == 'Totals');
      expect(
        totals.rows.any(
          (r) => r[0].toString().contains('labor with no rate'),
        ),
        isTrue,
      );
    });

    test('a line rate overrides the card for this job only', () {
      final provider = room();
      provider.laborRates = LaborRateBook.builtIn()
        ..upsert(const LaborRate(id: 'cts3', name: 'CTS III', hourlyRate: 95));
      final line = provider.addAvCostLabor(rateId: 'cts3', techs: 1);
      provider.updateAvCostLabor(
        line.copyWith(hours: 10, customRate: 140),
      );

      final estimate = computeRoomCost(
        model: buildAvFlowModel(provider),
        library: provider.avDeviceLibrary,
        settings: provider.avCost,
        rates: provider.laborRates,
      );
      expect(estimate.laborTotal, 1400);
      // The card itself is untouched.
      expect(provider.laborRates.byId('cts3')!.hourlyRate, 95);
    });

    test('untaxed labor stays out of the taxable base', () {
      final provider = room();
      provider.laborRates = LaborRateBook.builtIn()
        ..upsert(const LaborRate(id: 'cts3', name: 'CTS III', hourlyRate: 100));
      final line = provider.addAvCostLabor(rateId: 'cts3', techs: 1);
      provider.updateAvCostLabor(line.copyWith(hours: 10)); // 1000, untaxed
      provider.addAvNode(
        const AvNode(
          id: 'SW',
          label: 'Switcher',
          model: 'SW4 HD 4K PLUS',
          pos: Offset.zero,
          ports: [],
        ),
      );
      provider.setAvCostTax(percent: 10);

      final estimate = computeRoomCost(
        model: buildAvFlowModel(provider),
        library: provider.avDeviceLibrary,
        settings: provider.avCost,
        rates: provider.laborRates,
      );
      expect(estimate.subtotal, 1900, reason: '900 equipment + 1000 labor');
      expect(estimate.taxableBase, 900, reason: 'labor is not taxed');
      expect(estimate.tax, 90);
    });

    test('the rate card round-trips through its own file', () async {
      final book = LaborRateBook.builtIn()
        ..upsert(const LaborRate(id: 'cts4', name: 'CTS IV', hourlyRate: 125))
        ..upsert(
          LaborRate(
            id: book0Id,
            name: 'Night shift',
            hourlyRate: 180,
            taxable: true,
          ),
        );
      final target = p.join(dir.path, 'labor_rates.json');
      expect(await book.save(toPath: target), target);

      final back = await LaborRateBook.load(target);
      expect(back.byId('cts4')!.hourlyRate, 125);
      expect(back.byId(book0Id)!.name, 'Night shift');
      expect(back.byId('fms')!.isSet, isFalse, reason: 'FMS is a placeholder');
    });

    test('labor lines round-trip with the room', () {
      final provider = room();
      final line = provider.addAvCostLabor(rateId: 'cts3', techs: 3);
      provider.updateAvCostLabor(
        line.copyWith(hours: 6, description: 'Rack build'),
      );

      final restored = RoomCostSettings()
        ..readJson(provider.avCost.toJson());
      expect(restored.labor.single.techs, 3);
      expect(restored.labor.single.hours, 6);
      expect(restored.labor.single.description, 'Rack build');
      expect(restored.labor.single.rateId, 'cts3');
    });
  });

  group('the catalog search', () {
    test('ignores spaces, dashes and case', () {
      final provider = room();
      final entries = provider.avDeviceLibrary.all;

      for (final typed in [
        'dtpcrosspoint108',
        'DTP-CrossPoint-108',
        'dtp crosspoint 108',
        'DTPCROSSPOINT108',
      ]) {
        final hits = searchCatalog(entries, typed);
        expect(
          hits.first.model,
          'DTP CrossPoint 108 4K IPCP MA 70',
          reason: 'typed as "$typed"',
        );
      }
    });

    test('matches the part number and the maker too', () {
      final entries = room().avDeviceLibrary.all;
      expect(searchCatalog(entries, '60-1381-23').single.partNumber,
          '60-1381-23');
      expect(searchCatalog(entries, 'extron').length, 2);
    });

    test('an exact model sorts above a partial one', () {
      final entries = room().avDeviceLibrary.all;
      final hits = searchCatalog(entries, 'sw4hd4kplus');
      expect(hits.first.model, 'SW4 HD 4K PLUS');
    });

    test('a blank search returns everything', () {
      final entries = room().avDeviceLibrary.all;
      expect(searchCatalog(entries, '   ').length, entries.length);
    });
  });

  group('removing a config device', () {
    AppStateProvider seeded() {
      final provider = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          // dev_ counts live inside SYSTEM_SETUP; that is what decides which
          // device blocks the room actually has.
          'SYSTEM_SETUP': {
            'gui_full_room_name': 'Test Room',
            'dev_switchers': '1',
          },
          'SWITCHERDEVICE_1': {'name': 'Matrix', 'model': 'SW4 HD 4K PLUS'},
        };
      provider.loadAvFlowForCurrentConfig();
      provider.addAvNode(
        const AvNode(
          id: 'SWITCHERDEVICE_1',
          label: 'Matrix',
          model: 'SW4 HD 4K PLUS',
          pos: Offset.zero,
          fromConfig: true,
          ports: [],
        ),
      );
      return provider;
    }

    test('leaves it in the palette, flagged, instead of hiding it', () {
      final provider = seeded();
      provider.removeAvNode('SWITCHERDEVICE_1');

      final model = buildAvFlowModel(provider);
      expect(model.nodes, isEmpty);
      final listed = model.unplaced.singleWhere(
        (d) => d.key == 'SWITCHERDEVICE_1',
      );
      expect(
        listed.dismissed,
        isTrue,
        reason: 'the palette says why it is not on the canvas',
      );
    });

    test('clearing the dismissals is what Place all from config does', () {
      final provider = seeded();
      provider.removeAvNode('SWITCHERDEVICE_1');
      expect(provider.avDismissedDevices, contains('SWITCHERDEVICE_1'));

      provider.clearAvDismissedDevices();
      expect(provider.avDismissedDevices, isEmpty);
      expect(
        buildAvFlowModel(provider).unplaced.single.dismissed,
        isFalse,
      );
    });

    test('putting it back by hand also clears the removal', () {
      final provider = seeded();
      provider.removeAvNode('SWITCHERDEVICE_1');
      provider.addAvNode(
        const AvNode(
          id: 'SWITCHERDEVICE_1',
          label: 'Matrix',
          model: 'SW4 HD 4K PLUS',
          pos: Offset.zero,
          fromConfig: true,
          ports: [],
        ),
      );
      expect(provider.avDismissedDevices, isEmpty);
    });
  });

  group('Save All', () {
    test('writes the whole job into a folder named for the room', () async {
      final provider = room(name: 'Bessey 103 Lecture Hall');
      provider.addAvNode(
        const AvNode(
          id: 'SW',
          label: 'Switcher',
          model: 'SW4 HD 4K PLUS',
          pos: Offset.zero,
          rackUnits: 1,
          ports: [],
        ),
      );
      provider.setAvCostTax(percent: 8.25);
      provider.addAvCostFee(name: 'Freight', percent: 4);
      provider.avDeviceLibrary.upsert(
        const AvDeviceTemplate(model: 'My Custom Box', price: 42, ports: []),
      );

      final result = await saveProjectFolder(
        provider: provider,
        parentFolder: dir.path,
      );

      expect(p.basename(result.folder), 'Bessey_103_Lecture_Hall');
      final names = Directory(result.folder)
          .listSync()
          .map((e) => p.basename(e.path))
          .toList();

      expect(names, contains('BSS_103_config.json'));
      expect(names, contains('BSS_103_av_flow.json'));
      expect(names, contains('BSS_103_room_workbook.xlsx'));
      expect(names, contains('BSS_103_device_report.txt'));
      expect(names, contains('BSS_103_av_report.txt'));
      expect(names, contains('BSS_103_cost_estimate.txt'));
      expect(names, contains('av_devices.json'));
      expect(names, contains('labor_rates.json'));
      expect(names, contains('README.txt'));
    });

    test('the saved AV file carries the cost estimate', () async {
      final provider = room();
      provider.setAvCostTax(percent: 8.25);
      provider.addAvCostFee(name: 'Freight', percent: 4);
      final line = provider.addAvCostLabor(rateId: 'cts3', techs: 2);
      provider.updateAvCostLabor(line.copyWith(hours: 8));

      final result = await saveProjectFolder(
        provider: provider,
        parentFolder: dir.path,
      );
      final doc = jsonDecode(
        File(p.join(result.folder, 'BSS_103_av_flow.json')).readAsStringSync(),
      );
      final cost = doc['cost'] as Map;
      expect(cost['taxPercent'], 8.25);
      expect((cost['fees'] as List).single['name'], 'Freight');
      expect((cost['labor'] as List).single['techs'], 2);
    });

    test('says which diagrams it could not capture', () async {
      final provider = room();
      final result = await saveProjectFolder(
        provider: provider,
        parentFolder: dir.path,
      );
      // No PNGs were handed in — the folder says so rather than being
      // quietly short of three images.
      expect(result.skipped.where((s) => s.endsWith('captured')).length, 3);
      final readme = File(
        p.join(result.folder, 'README.txt'),
      ).readAsStringSync();
      expect(readme, contains('Not included'));
      expect(readme, contains('rack elevation'));
    });

    test('backs up only the catalog entries that are yours', () async {
      final provider = room();
      final result = await saveProjectFolder(
        provider: provider,
        parentFolder: dir.path,
      );
      final doc = jsonDecode(
        File(p.join(result.folder, 'av_devices.json')).readAsStringSync(),
      );
      expect((doc['devices'] as List).length, 2);
    });

    test('a room with no name still gets a sensible folder', () async {
      final provider = room(name: '');
      final result = await saveProjectFolder(
        provider: provider,
        parentFolder: dir.path,
      );
      expect(p.basename(result.folder), 'BSS_103');
    });
  });

  test('saving the config writes the estimate beside it', () async {
    final configPath = p.join(dir.path, 'BSS103_config.json');
    File(configPath).writeAsStringSync('{}');

    final provider = room()..currentConfigPath = configPath;
    provider.setAvCostTax(percent: 7);
    provider.addAvCostFee(name: 'Install', percent: 12);

    // The plain "save the working file" path, not a diagram button.
    expect(await provider.saveCurrentConfigToFile(), configPath);

    final sidecar = File(p.join(dir.path, 'BSS103_config_av_flow.json'));
    expect(sidecar.existsSync(), isTrue,
        reason: 'the cost estimate is part of the project');
    final cost = jsonDecode(sidecar.readAsStringSync())['cost'] as Map;
    expect(cost['taxPercent'], 7);
    expect((cost['fees'] as List).single['name'], 'Install');
  });
}

/// A generated id used by the rate-card round-trip test.
final String book0Id = LaborRateBook.builtIn().newId('night shift');
