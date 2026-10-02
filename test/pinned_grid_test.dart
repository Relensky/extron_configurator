import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:extron_configurator/pinned_grid.dart';

/// The pinned grid's scrollbars: one down the right, one along the bottom.
void main() {
  testWidgets('a desktop grid has one bar each way, not one per half',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PinnedGrid(
              frozenWidth: 120,
              headerHeight: 40,
              bodyWidth: 3000,
              bodyHeight: 3000,
              maxHeight: 500,
              corner: const SizedBox(),
              header: const SizedBox(width: 3000, height: 40),
              rowCount: 100,
              rowExtent: 30,
              frozenRowBuilder: (_, i) => Text('Room $i'),
              bodyRowBuilder: (_, _) => const SizedBox(width: 3000),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final bars = tester
          .widgetList<RawScrollbar>(find.byWidgetPredicate((w) => w is RawScrollbar))
          .toList();
      expect(bars, hasLength(2));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
