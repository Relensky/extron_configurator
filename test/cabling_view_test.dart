import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_view.dart' show buildAvFlowModel;
import 'package:extron_configurator/cabling_schematic.dart';
import 'package:extron_configurator/cabling_view.dart';

/// The Cabling tab is edited, not just looked at, so the controls that edit it
/// have to be somewhere a person can find. Telling somebody to "set the count
/// in the toolbar" and then hiding the field at the end of a row that has
/// already wrapped is the same as not having the field at all — so what is
/// selected, and everything that can be done to it, gets a bar of its own.
void main() {
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  Future<void> pumpTab(WidgetTester tester, AppStateProvider provider) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: CablingView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('the selection bar', () {
    testWidgets('stays away until something is selected', (tester) async {
      final provider = room();
      await pumpTab(tester, provider);
      expect(find.widgetWithText(TextButton, 'Rename'), findsNothing);
      expect(find.widgetWithText(TextField, 'Cables'), findsNothing);
    });

    testWidgets('a run carries its count and cable type as fields', (
      tester,
    ) async {
      final provider = room();
      final a = provider.addCablingBox(kind: CablingBoxKind.pullBox);
      final b = provider.addCablingBox(kind: CablingBoxKind.pullBox);
      final run = provider.addCablingBundle(
        fromBoxId: a.id,
        toBoxId: b.id,
        count: 2,
        cableType: 'Cat 6a',
      )!;
      await pumpTab(tester, provider);

      // The two pull boxes land in one column, so the run between them — and
      // the pad that selects it — sits at the midpoint of their centres.
      final origin = tester.getTopLeft(find.byType(InteractiveViewer));
      final from = provider.avCabling.extraBoxes.first.rect.center;
      final to = provider.avCabling.extraBoxes.last.rect.center;
      await tester.tapAt(origin + (from + to) / 2 - const Offset(0, 8));
      await tester.pumpAndSettle();

      final count = find.widgetWithText(TextField, 'Cables');
      expect(
        count,
        findsOneWidget,
        reason: 'the run has to be selectable by clicking it',
      );
      expect(find.widgetWithText(TextField, 'Cable'), findsOneWidget);

      // Committed on Enter, not per keystroke: '13' typed a digit at a time
      // would leave '1' behind as an undo entry of its own.
      await tester.enterText(count, '13');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final drawing = provider.cablingSchematic(buildAvFlowModel(provider));
      expect(drawing.bundles.firstWhere((x) => x.id == run.id).count, 13);
    });
  });

  group('devices on the drawing', () {
    testWidgets('the picker drops the gear it was asked for', (tester) async {
      final provider = room();
      await pumpTab(tester, provider);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Device'));
      await tester.pumpAndSettle();
      expect(find.text('Which device?'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('cabling_device_projector')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final box = provider.avCabling.extraBoxes.single;
      expect(box.kind, CablingBoxKind.device);
      expect(box.shape, 'projector');
      // Named for the gear, not "Device" — it is what the person holding the
      // drawing calls the thing they are pulling to.
      expect(box.label, 'Projector');
      // Drawn with the same icon the schematic gives a projector.
      expect(find.byIcon(Icons.connected_tv), findsWidgets);
    });

    testWidgets('a second box does not land on top of the first', (
      tester,
    ) async {
      final provider = room();
      await pumpTab(tester, provider);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Device'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cabling_device_projector')));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Device'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cabling_device_speaker')));
      await tester.pumpAndSettle();

      final boxes = provider.avCabling.extraBoxes;
      expect(boxes, hasLength(2));
      expect(boxes.first.pos, isNot(boxes.last.pos));
    });

    testWidgets('a pathway belongs on the other side of the sheet', (
      tester,
    ) async {
      // Regression: every hand-added box landed at one fixed spot, so adding a
      // pathway after a device buried one under the other.
      final provider = room();
      await pumpTab(tester, provider);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Device'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cabling_device_projector')));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Pathway'));
      await tester.pumpAndSettle();

      final device = provider.avCabling.extraBoxes.first;
      final pathway = provider.avCabling.extraBoxes.last;
      expect(pathway.kind, CablingBoxKind.pathway);
      expect(device.rect.overlaps(pathway.rect), isFalse);

      // And it is named for what it is, so the label on the drawing is the
      // label somebody can edit rather than a fixed caption.
      expect(pathway.label, 'Network Pathway back to TR');
      expect(find.text('Network Pathway back to TR'), findsWidgets);
    });

    testWidgets('renaming the pathway changes what the drawing says', (
      tester,
    ) async {
      final provider = room();
      final pathway = provider.addCablingBox(kind: CablingBoxKind.pathway);
      await pumpTab(tester, provider);

      provider.setCablingBoxLabel(pathway.id, 'Conduit to IDF-2B');
      await tester.pumpAndSettle();

      expect(find.text('Conduit to IDF-2B'), findsWidgets);
      expect(find.text('Network Pathway back to TR'), findsNothing);
    });
  });
}
