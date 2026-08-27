import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_swap_dialogs.dart'
    show applyControlSwap;
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  A SWAP THAT CHANGES WHAT THE DEVICE IS
/// ============================================================================
///  Most swaps trade like for like - one projector for a bigger one - and the
///  block stays where it is with a new model and a new driver on it.
///
///  But the swap is also how somebody answers "what if we used a switcher
///  instead of the DSP", and rewriting the model in place left that block a
///  DSPDEVICE: the wrong family's fields on the Devices tab, `dev_dsps` still
///  counting a DSP the room does not have, `dev_switchers` still zero, and the
///  schematic drawing it in the wrong section. The config said one thing and
///  the quote and the drawing said another.
///
///  So the block MOVES. It is rebuilt in the family the model belongs to, off
///  that family's defaults and the driver's own DEVICE_INFO, and the family it
///  left is renumbered and recounted behind it.
/// ============================================================================
void main() {
  late UiSchema schema;
  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
  });

  AvDeviceLibrary catalog() => AvDeviceLibrary.empty()
    ..upsert(
      const AvDeviceTemplate(
        model: 'DMP 128',
        category: 'DSP',
        price: 2000,
        ports: [],
      ),
    )
    ..upsert(
      const AvDeviceTemplate(
        model: 'IN1608',
        category: 'Switcher',
        price: 3000,
        ports: [],
      ),
    )
    ..upsert(
      const AvDeviceTemplate(
        model: 'DMP 64',
        category: 'DSP',
        price: 1400,
        ports: [],
      ),
    );

  /// A room whose DSPs are drawn AND in the config, so a swap has both halves
  /// to move.
  AppStateProvider room({int dsps = 1}) {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = schema
      ..roomConfig = {
        'SYSTEM_SETUP': {
          'gui_full_room_name': 'Test Room',
          'dev_dsps': '$dsps',
          'dev_switchers': '0',
        },
        for (int i = 1; i <= dsps; i++)
          'DSPDEVICE_$i': {
            'name': 'DSP $i',
            'model': 'DMP 128',
            'module': 'modules.device.dmp_128',
            'ip_address': '10.1.1.5$i',
          },
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = catalog();
    p.modelRegistry['IN1608'] = const ModelEntry(
      model: 'IN1608',
      module: 'in1608',
      explicit: true,
    );
    for (int i = 1; i <= dsps; i++) {
      p.addAvNode(
        AvNode(
          id: 'DSPDEVICE_$i',
          label: 'DSP $i',
          model: 'DMP 128',
          pos: Offset.zero,
          fromConfig: true,
          ports: const [],
        ),
      );
    }
    return p;
  }

  test('a like-for-like swap leaves the block exactly where it is', () {
    final p = room();
    applyControlSwap(p, ['DSPDEVICE_1'], 'DMP 64');

    expect((p.roomConfig['DSPDEVICE_1'] as Map)['model'], 'DMP 64');
    expect(p.roomConfig['SYSTEM_SETUP']['dev_dsps'], '1');
    expect(p.roomConfig['SYSTEM_SETUP']['dev_switchers'], '0');
    // The room's own settings are kept, which is the whole bargain of a swap
    // that does not change what the device is.
    expect((p.roomConfig['DSPDEVICE_1'] as Map)['ip_address'], '10.1.1.51');
  });

  group('swapping a DSP for a switcher', () {
    test('moves the block into the switcher family', () {
      final p = room();
      applyControlSwap(p, ['DSPDEVICE_1'], 'IN1608');

      expect(p.roomConfig['DSPDEVICE_1'], isNull);
      final moved = p.roomConfig['SWITCHERDEVICE_1'];
      expect(moved, isA<Map>());
      expect((moved as Map)['model'], 'IN1608');
    });

    test('both counts follow, so the Setup Wizard says what the room has', () {
      final p = room();
      applyControlSwap(p, ['DSPDEVICE_1'], 'IN1608');

      expect(p.roomConfig['SYSTEM_SETUP']['dev_dsps'], '0');
      expect(p.roomConfig['SYSTEM_SETUP']['dev_switchers'], '1');
      // And the answer every reader of the room actually asks.
      expect(
        activeDeviceKeysIn(p.roomConfig, p.uiSchema.deviceCountMap),
        ['SWITCHERDEVICE_1'],
      );
    });

    test('the module that should be in use is on the new block', () {
      final p = room();
      applyControlSwap(p, ['DSPDEVICE_1'], 'IN1608');

      final moved = p.roomConfig['SWITCHERDEVICE_1'] as Map;
      expect(moved['module'], 'modules.device.in1608');
      expect(
        p.deviceModelModuleFault('SWITCHERDEVICE_1'),
        isNull,
        reason: 'model and module agree, so nothing to flag',
      );
    });

    test('a model no driver claims is left blank and marked', () {
      final p = room();
      p.avDeviceLibrary.upsert(
        const AvDeviceTemplate(
          model: 'Unclaimed Switcher',
          category: 'Switcher',
          price: 900,
          ports: [],
        ),
      );

      applyControlSwap(p, ['DSPDEVICE_1'], 'Unclaimed Switcher');

      final moved = p.roomConfig['SWITCHERDEVICE_1'] as Map;
      expect(moved['model'], 'Unclaimed Switcher');
      // Blank rather than the DSP's driver: a block naming the old driver
      // under the new name reads as configured and commissions the room as
      // the wrong device.
      expect(moved['module'], '');
      expect(
        p.deviceModelModuleFault('SWITCHERDEVICE_1')?.fault,
        ModelModuleFault.noModule,
        reason: 'the Devices tab shows this one in red until it is answered',
      );
    });

    test('the drawn box comes with it, so the two stay one device', () {
      final p = room();
      applyControlSwap(p, ['DSPDEVICE_1'], 'IN1608');

      expect(p.avNodeById('DSPDEVICE_1'), isNull);
      expect(p.avNodeById('SWITCHERDEVICE_1'), isNotNull);
      expect(p.avDismissedDevices.contains('SWITCHERDEVICE_1'), isFalse);
    });

    test('the address the room is cabled on comes across', () {
      final p = room();
      applyControlSwap(p, ['DSPDEVICE_1'], 'IN1608');

      // A fact about the cable in the wall, not about the box on the end of
      // it. Everything else on the block is the new family's and the new
      // driver's.
      expect(
        (p.roomConfig['SWITCHERDEVICE_1'] as Map)['ip_address'],
        '10.1.1.51',
      );
    });

    test('taking the defaults instead leaves the old address behind', () {
      final p = room();
      applyControlSwap(p, ['DSPDEVICE_1'], 'IN1608', applyDefaults: true);

      final moved = p.roomConfig['SWITCHERDEVICE_1'] as Map;
      expect(moved['model'], 'IN1608');
      expect(moved['ip_address'], isNot('10.1.1.51'));
    });

    test('the family left behind is renumbered, not left with a hole', () {
      final p = room(dsps: 3);
      // The middle one, so a hole is what a naive removal would leave.
      applyControlSwap(p, ['DSPDEVICE_2'], 'IN1608');

      expect(p.roomConfig['SYSTEM_SETUP']['dev_dsps'], '2');
      expect(p.roomConfig['DSPDEVICE_3'], isNull);
      // _3 slid down onto the number _2 vacated, and its box came with it.
      expect((p.roomConfig['DSPDEVICE_2'] as Map)['ip_address'], '10.1.1.53');
      expect(p.avNodeById('DSPDEVICE_2'), isNotNull);
      expect(
        activeDeviceKeysIn(p.roomConfig, p.uiSchema.deviceCountMap),
        containsAll(['DSPDEVICE_1', 'DSPDEVICE_2', 'SWITCHERDEVICE_1']),
      );
    });

    test('two of them at once move without treading on each other', () {
      final p = room(dsps: 3);
      // Ascending order, which is the order a caller naturally has them in -
      // and the order that would have lost the second one to the renumbering
      // of the first.
      applyControlSwap(p, ['DSPDEVICE_1', 'DSPDEVICE_2'], 'IN1608');

      expect(p.roomConfig['SYSTEM_SETUP']['dev_dsps'], '1');
      expect(p.roomConfig['SYSTEM_SETUP']['dev_switchers'], '2');
      expect((p.roomConfig['SWITCHERDEVICE_1'] as Map)['model'], 'IN1608');
      expect((p.roomConfig['SWITCHERDEVICE_2'] as Map)['model'], 'IN1608');
      // The one that was not swapped is the one still on the DSP side.
      expect((p.roomConfig['DSPDEVICE_1'] as Map)['ip_address'], '10.1.1.53');
    });
  });
}
