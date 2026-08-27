import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_only_notice.dart';
import 'package:extron_configurator/control_gaps.dart';
import 'package:extron_configurator/dynamic_devices_view.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  A PRODUCT THAT NEVER NEEDED A DRIVER
/// ============================================================================
///  The catalog can say that a product has no control interface at all — a
///  laptop plate, a passive splitter, a mount. It is a decision about the
///  PRODUCT, made once, and every room that has one should stop being asked
///  about it.
///
///  It did not. The room's own missing-module list walks the config blocks and
///  only looked at whether `module` was empty, so a plate somebody had already
///  been through and settled sat on the nag list, in red, with no way to clear
///  it except to leave the room wrong.
///
///  Now: off the warning, still on the page. "The laptop plates are
///  deliberately driverless" is a thing somebody checking a room file wants
///  CONFIRMED, which is a note and not a fault.
/// ============================================================================
void main() {
  late UiSchema schema;
  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
  });

  /// A catalog where the plate is settled and the display is not.
  AvDeviceLibrary catalog() => AvDeviceLibrary.empty()
    ..upsert(
      const AvDeviceTemplate(
        model: 'Laptop Plate',
        category: 'Misc',
        neverControlled: true,
        ports: [],
      ),
    )
    ..upsert(
      const AvDeviceTemplate(model: 'Display 86', category: 'Display', ports: []),
    );

  /// A room with one of each: a plate nothing drives, and a display waiting
  /// for a driver.
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = schema
      ..avDeviceLibrary = catalog();
    p.roomConfig = {
      'SYSTEM_SETUP': {'dev_projectors': '1', 'dev_usb_switchers': '1'},
      'PROJECTORDEVICE_1': {
        'name': 'Display',
        'model': 'Display 86',
        'module': '',
      },
      'USBDEVICE_1': {
        'name': 'Lectern laptop plate',
        'model': 'Laptop Plate',
        'module': '',
      },
    };
    return p;
  }

  group('the room\'s own lists', () {
    test('a settled product is off the missing-module list', () {
      final p = room();
      expect(
        p.devicesMissingModules.map((d) => d.key),
        ['PROJECTORDEVICE_1'],
        reason: 'only the display is actually waiting for a driver',
      );
    });

    test('and is listed separately, so it can still be confirmed', () {
      final p = room();
      final settled = p.devicesNeedingNoModule;
      expect(settled, hasLength(1));
      expect(settled.single.key, 'USBDEVICE_1');
      expect(settled.single.name, 'Lectern laptop plate');
      expect(settled.single.model, 'Laptop Plate');
    });

    test('un-flagging the product puts it back on the warning', () {
      final p = room();
      p.avDeviceLibrary.upsert(
        const AvDeviceTemplate(
          model: 'Laptop Plate',
          category: 'Misc',
          ports: [],
        ),
      );
      expect(
        p.devicesMissingModules.map((d) => d.key),
        containsAll(['PROJECTORDEVICE_1', 'USBDEVICE_1']),
      );
      expect(p.devicesNeedingNoModule, isEmpty);
    });

    test('a device with a module is on neither list', () {
      final p = room();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'module', 'modules.device.x');
      expect(p.devicesMissingModules, isEmpty);
      expect(p.devicesNeedingNoModule.single.key, 'USBDEVICE_1');
    });
  });

  group('the device page', () {
    /// Pumped rather than settled: the keep-alive slot spins while a module is
    /// parsed, and pumpAndSettle waits for an animation that never stops.
    Future<void> pump(
      WidgetTester tester,
      AppStateProvider provider,
      String deviceKey,
    ) async {
      tester.view.physicalSize = const Size(1400, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(
              body: DeviceConfigurationForm(deviceKey: deviceKey),
            ),
          ),
        ),
      );
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('says the plate needs no module, and does not say it in red',
        (tester) async {
      final p = room();
      await pump(tester, p, 'USBDEVICE_1');

      expect(
        find.byKey(const ValueKey('model_module_banner_USBDEVICE_1')),
        findsOneWidget,
        reason: 'the block still says what the story is',
      );
      expect(
        find.text('No module needed for "Laptop Plate"'),
        findsOneWidget,
      );
      expect(
        find.textContaining('will not commission'),
        findsNothing,
        reason: 'nothing here is broken',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the display beside it is still called out', (tester) async {
      final p = room();
      await pump(tester, p, 'PROJECTORDEVICE_1');
      expect(
        find.text('No python module for model "Display 86"'),
        findsOneWidget,
      );
    });
  });

  group('the room banner', () {
    Future<void> pumpBanner(WidgetTester tester, AppStateProvider p) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: MissingModulesBanner()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('counts the display and not the plate', (tester) async {
      final p = room();
      await pumpBanner(tester, p);

      expect(
        find.text('1 device the control system cannot drive yet'),
        findsOneWidget,
      );
      // The plate is under it as a note rather than in the count.
      expect(
        find.textContaining('flagged in the catalog as needing no module'),
        findsOneWidget,
      );
    });

    testWidgets('a room whose only gap is settled shows a note, not a warning',
        (tester) async {
      final p = room();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'module', 'modules.device.x');
      await pumpBanner(tester, p);

      expect(
        find.textContaining('cannot drive yet'),
        findsNothing,
        reason: 'there is nothing wrong with this room',
      );
      expect(
        find.text('1 device flagged as needing no module'),
        findsOneWidget,
      );
      expect(find.textContaining('Lectern laptop plate'), findsOneWidget);
    });
  });

  test('a settled block off the diagram is not an undriven device', () {
    final p = room();
    final gaps = controlGapsForRoom(
      config: p.roomConfig,
      model: const AvFlowModel(
        nodes: [],
        cables: [],
        racks: [],
        rackSlots: {},
        rackItems: [],
        canvasSize: Size.zero,
        roomTitle: 'Test Room',
        unplaced: [],
        locations: [],
      ),
      deviceCountMap: p.uiSchema.deviceCountMap,
      library: p.avDeviceLibrary,
      moduleForModel: p.moduleForModel,
    );

    // The display, and only the display: a plate nothing drives is not a gap
    // whether it was drawn or not.
    expect(gaps.map((g) => g.device), ['Display']);
  });
}
