import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/live_text_field.dart';

/// The tax and PDF boxes on the Cost tab sit in one line, whatever the note
/// above the tax rate says.
void main() {
  testWidgets('the tax rate box lines up with tax name and PDF title',
      (tester) async {
    tester.view.physicalSize = const Size(1900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = AvDeviceLibrary.empty();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ),
    );
    await tester.pumpAndSettle();

    // The note is there, above the rate.
    expect(find.byKey(const ValueKey('cost_tax_source')), findsOneWidget);

    Rect box(String fieldId) => tester.getRect(
      find
          .descendant(
            of: find.byWidgetPredicate(
              (w) => w is LiveTextField && w.fieldId == fieldId,
            ),
            matching: find.byType(InputDecorator),
          )
          .first,
    );

    final name = box('taxLabel');
    final rate = box('taxPercent');
    final title = box('cost_pdf_title');
    expect(rate.center.dy, closeTo(name.center.dy, 0.5));
    expect(title.center.dy, closeTo(name.center.dy, 0.5));
  });
}
