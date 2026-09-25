import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';

/// ============================================================================
///  DISPLAY SCALING
/// ============================================================================
///  Windows display scaling shrinks the room the app has to lay out in: a
///  1366x768 laptop at 125% gives it about 1093x590 (after the title bar), a
///  1920x1080 screen at 150% about 1280x680. Every tab has to come up there
///  without anything overflowing out of sight.
void main() {
  for (final size in const [Size(1093, 590), Size(1280, 680)]) {
    testWidgets(
        'every tab fits at ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final provider = AppStateProvider();
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: provider,
        child: const MaterialApp(home: MainDashboard()),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final failures = <String>[];
      void check(String where) {
        final e = tester.takeException();
        if (e != null) failures.add('$where: $e');
      }

      check('start');
      for (final tab in AppTab.values) {
        provider.selectTab(tab.index);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        check(tab.name);
      }
      expect(failures, isEmpty);
    });
  }
}
