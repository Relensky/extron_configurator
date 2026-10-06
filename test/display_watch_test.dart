import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:extron_configurator/display_watch.dart';

void main() {
  testWidgets('the key pressed just before a close is noted', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final watch = DisplayWatch.instance;
    watch.start();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f4);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    expect(watch.lastKeyNote(), contains('Alt+F4'));
    // Before the test ends: its once-a-second check is a timer.
    watch.stop();
    expect(tester.takeException(), isNull);
  });
}
