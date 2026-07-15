import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';

/// Smoke test for the state a FRESH INSTALL lands in: no files associated, so
/// every path setting is blank. Renders and scrolls the whole App Config tab
/// and asserts it builds without throwing.
///
/// (It also covers the field keys now being namespaced per setting. With the
/// bare value as the key, four siblings shared a ValueKey('') when all paths
/// were blank. That is a latent hazard worth avoiding, though testing showed
/// it was NOT the cause of the sliver_multi_box_adaptor child-order assertion.)
void main() {
  testWidgets('App Config renders with every path blank (no duplicate keys)',
      (WidgetTester tester) async {
    // Desktop-sized surface: the default 800x600 test window is narrower than
    // the app ever runs at, and the side-by-side path rows overflow it.
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // autoLoadSettings: false — the async load rewrites the real
    // app_config.json (and can corrupt it when tests run concurrently), and
    // this test wants the untouched fresh-install state anyway.
    final provider = AppStateProvider(autoLoadSettings: false);

    // The state a fresh install lands in: nothing chosen, nothing associated.
    expect(provider.modulesPath, isEmpty);
    expect(provider.buildingsFilePath, isEmpty);
    expect(provider.processorsFilePath, isEmpty);
    expect(provider.rootFolderPath, isEmpty);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: AppSettingsView())),
      ),
    );
    await tester.pump();

    // Before the fix this threw the sliver assertion instead of building.
    expect(tester.takeException(), isNull);
    expect(find.byType(AppSettingsView), findsOneWidget);

    // Scroll the whole list: the assertion fires as children are lazily
    // built and inserted, so a static first frame alone would not catch it.
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
