import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_view.dart' show buildAvFlowModel;
import 'package:extron_configurator/cable_colors_dialog.dart';
import 'package:extron_configurator/room_locations.dart';

/// The Schematic tab has had a one-dialog "Colors" button for as long as it has
/// had lines. The two sheets the trades are actually handed had nothing of the
/// kind: a colour could only be changed by selecting one run at a time, which
/// is the wrong shape for "make the network runs blue" and is how a drawing
/// ends up with three shades of network on it.
void main() {
  /// A room with two low-voltage runs of different cable types.
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    final a = p.addAvLocation(const RoomLocation(id: '', name: 'Lectern'));
    final b = p.addAvLocation(const RoomLocation(id: '', name: 'Rack'));
    p.addAvScreenSwitch(
      ScreenSwitch(
        id: '',
        label: 'Front screen',
        startLocationId: a.id,
        endLocationId: b.id,
        cableType: '18/2 plenum',
      ),
    );
    p.addAvScreenSwitch(
      ScreenSwitch(
        id: '',
        label: 'Rear shades',
        startLocationId: a.id,
        endLocationId: b.id,
        cableType: 'Cat 6',
      ),
    );
    return p;
  }

  test('every cable type on the drawing is offered, once each', () {
    final p = room();
    final drawing = p.cablingSchematic(buildAvFlowModel(p));
    final types = cablingTypesIn(drawing);
    expect(types.map((t) => t.type), containsAll(['18/2 plenum', 'Cat 6']));
    // One row per type, however many runs carry it.
    expect(types.length, types.map((t) => t.type).toSet().length);
    for (final t in types) {
      expect(t.keys, isNotEmpty, reason: 'a colour needs somewhere to go');
    }
  });

  testWidgets('picking a swatch recolours every run of that type',
      (tester) async {
    final p = room();
    final drawing = p.cablingSchematic(buildAvFlowModel(p));

    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => showCableColorsDialog(ctx, p, drawing),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Cable colours'), findsOneWidget);
    expect(find.text('Cat 6'), findsOneWidget);

    // The first swatch on the Cat 6 row.
    final swatch = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey &&
          (w.key as ValueKey).value.toString().startsWith(
                'cable_type_color_Cat 6_',
              ),
    );
    expect(swatch, findsWidgets);
    await tester.tap(swatch.first);
    await tester.pumpAndSettle();

    // Written as a TYPE colour, which is what every sheet reads.
    expect(p.avCabling.typeColors, isNotEmpty);
    final after = cablingTypesIn(p.cablingSchematic(buildAvFlowModel(p)));
    final cat6 = after.firstWhere((t) => t.type == 'Cat 6');
    expect(p.hasCablingTypeColor(cat6.keys), isTrue);
  });
}
