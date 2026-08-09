import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';

/// Reproduction: toggling dark/light while the App Config tab is open throws
///   'child == null || indexOf(child) > index': is not true
///   (sliver_multi_box_adaptor.dart _debugVerifyChildOrder)
///
/// Renders the REAL app (RoomConfigApp -> MainDashboard -> App Config tab)
/// with the real processors.json / buildings.json loaded, so the searchable
/// room picker has its full option list.
void main() {
  // Run the same flow under both theme styles — Auris and Classic build their
  // text styles with different `inherit` flags, which the app already has a
  // remount workaround for.
  for (final style in ['classic', 'auris']) {
    testWidgets('toggle theme on the App Config tab ($style)',
        (WidgetTester tester) async {
      await _run(tester, style);
    });
  }
}

Future<void> _run(WidgetTester tester, String style) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // autoLoadSettings: false — the async load rewrites the real
    // app_config.json; this test seeds all the state it needs directly.
    final provider = AppStateProvider(autoLoadSettings: false);
    provider.themeStyle = style;

    // Load the real data the app has at runtime (the async boot load can't be
    // awaited from testWidgets, so seed it directly).
    provider.processors =
        jsonDecode(File('processors.json').readAsStringSync()) as List<dynamic>;
    provider.buildings = jsonDecode(File('buildings.json').readAsStringSync())
        as Map<String, dynamic>;

    // Skip the first-run dialog so we land straight on the tabs.
    provider.settingsLoaded = true;
    provider.firstRunSetupNeeded = false;
    provider.selectTab(AppTab.appConfig.index);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const RoomConfigApp(),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull, reason: 'App Config should render');

    // Scroll so leading children are disposed and trailing ones lazily built.
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pump();
    expect(tester.takeException(), isNull, reason: 'scrolling alone is fine');

    // The reported trigger: flip dark/light with the tab open. Not awaited —
    // the toolbar button calls it the same way (it notifies synchronously and
    // persists in the background).
    provider.toggleTheme();
    await tester.pump();

    expect(tester.takeException(), isNull,
        reason: 'theme toggle must not corrupt the sliver child order');
}
