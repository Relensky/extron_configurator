import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/dynamic_devices_view.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  THE MODEL AND THE DRIVER, IN RED
/// ============================================================================
///  A device block names a product and names the driver that talks to it, and
///  nothing kept the two together. Retype the model, or swap the box from the
///  Cost tab, and the module underneath went on naming a driver for the product
///  that used to be there — with every field filled in, so the block reads as
///  finished. That is the config nobody re-checks, and it commissions a room as
///  a device the room does not contain.
///
///  The banner is derived from the config rather than remembered by the page,
///  which is what makes it survive a swap made on another tab, a save and a
///  reopen — and what makes picking a module the thing that clears it.
///
///  It has to stay quiet where it cannot know, or it becomes wallpaper: no
///  model yet, or a driver that never said which models it covers.
/// ============================================================================
void main() {
  late UiSchema schema;
  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
  });

  AppStateProvider room(Map<String, dynamic> device) {
    final p = AppStateProvider(autoLoadSettings: false)..uiSchema = schema;
    p.roomConfig = {
      'SYSTEM_SETUP': {'dev_projectors': '1'},
      'PROJECTORDEVICE_1': device,
    };
    return p;
  }

  /// Pumped rather than settled: the keep-alive slot spins while a module is
  /// parsed, and pumpAndSettle waits for an animation that never stops.
  Future<void> pump(WidgetTester tester, AppStateProvider provider) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const MaterialApp(
          home: Scaffold(
            body: DeviceConfigurationForm(deviceKey: 'PROJECTORDEVICE_1'),
          ),
        ),
      ),
    );
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  final banner = find.byKey(
    const ValueKey('model_module_banner_PROJECTORDEVICE_1'),
  );

  group('a model with no module', () {
    testWidgets('is called out in red', (tester) async {
      final p = room({'model': 'Display 86', 'module': ''});
      await pump(tester, p);

      expect(banner, findsOneWidget);
      expect(
        find.text('No python module for model "Display 86"'),
        findsOneWidget,
      );
    });

    testWidgets('clears the moment a module is picked', (tester) async {
      final p = room({'model': 'Display 86', 'module': ''});
      await pump(tester, p);
      expect(banner, findsOneWidget);

      // What the module field's own onSelected does. The driver claims
      // nothing in particular, so nothing contradicts the model: the user's
      // pick is the answer, and the page takes it.
      p.updateDeviceValue(
        'PROJECTORDEVICE_1',
        'module',
        'modules.device.display_86',
      );
      await tester.pump();

      expect(banner, findsNothing);
    });
  });

  group('a module that drives something else', () {
    AppStateProvider mismatched() {
      final p = room({
        'model': 'Display 86',
        'module': 'modules.device.display_65',
      });
      // What the driver itself says it covers, as the module parser records
      // it — DEVICE_INFO models, or the self.Models keys behind them.
      p.moduleModels['display_65'] = ['Display 65', 'Display 55'];
      return p;
    }

    testWidgets('is called out, and names what it does drive', (tester) async {
      final p = mismatched();
      await pump(tester, p);

      expect(banner, findsOneWidget);
      expect(
        find.text('"Display 86" is not a model display_65 drives'),
        findsOneWidget,
      );
      expect(find.textContaining('Display 65, Display 55'), findsOneWidget);
    });

    testWidgets('goes away when the right module is picked', (tester) async {
      final p = mismatched();
      p.moduleModels['display_86'] = ['Display 86'];
      await pump(tester, p);
      expect(banner, findsOneWidget);

      p.updateDeviceValue(
        'PROJECTORDEVICE_1',
        'module',
        'modules.device.display_86',
      );
      await tester.pump();

      expect(banner, findsNothing);
    });
  });

  group('quiet where it cannot know', () {
    testWidgets('a device with no model yet', (tester) async {
      // Unfinished is not wrong, and a banner on every new device is a banner
      // nobody reads.
      final p = room({'model': '', 'module': ''});
      await pump(tester, p);
      expect(banner, findsNothing);
    });

    testWidgets('a driver that never said which models it covers',
        (tester) async {
      // Plenty of drivers list none, and the modules path may not have been
      // read at all. "It says nothing" is not evidence against the model.
      final p = room({
        'model': 'Display 86',
        'module': 'modules.device.something',
      });
      await pump(tester, p);
      expect(banner, findsNothing);
    });

    testWidgets('a model the driver lists, spelled differently',
        (tester) async {
      final p = room({
        'model': 'display 86',
        'module': 'modules.device.display_86',
      });
      p.moduleModels['display_86'] = ['DISPLAY 86'];
      await pump(tester, p);
      expect(banner, findsNothing,
          reason: 'the same forgiveness module resolution gives — people type '
              "'tr311hw' for 'TR311HW'");
    });
  });

  group('the rule itself', () {
    test('reads the config, so it survives the page it is drawn on', () {
      final p = room({'model': 'Display 86', 'module': ''});
      final fault = p.deviceModelModuleFault('PROJECTORDEVICE_1');
      expect(fault?.fault, ModelModuleFault.noModule);
      expect(fault?.model, 'Display 86');
      expect(fault?.claims, isEmpty);
    });

    test('setModelWithoutModule is what leaves it in that state', () {
      final p = room({
        'model': 'Display 65',
        'module': 'modules.device.display_65',
        'ip_address': '10.1.1.51',
      });
      p.setModelWithoutModule('PROJECTORDEVICE_1', 'Display 86');

      final dev = p.roomConfig['PROJECTORDEVICE_1'] as Map;
      expect(dev['model'], 'Display 86');
      expect(dev['module'], '');
      // The install is untouched: the driver is the open question, not the
      // address the box answers on.
      expect(dev['ip_address'], '10.1.1.51');
      expect(
        p.deviceModelModuleFault('PROJECTORDEVICE_1')?.fault,
        ModelModuleFault.noModule,
      );
    });
  });
}
