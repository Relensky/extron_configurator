import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/log_viewer/log_viewer.dart';
import 'package:extron_configurator/settings_kit/settings_kit.dart';

// The settings kit is byte-identical in every CTS app; so is this test, but
// for the package name above.

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  setUp(SettingsSection.forgetOpenForTest);

  testWidgets('a section opens and closes, and Expand all reaches it',
      (tester) async {
    Widget page(bool open, int generation) => _host(SettingsSectionsScope(
          open: open,
          generation: generation,
          child: const SettingsSection(
            id: 'demo',
            title: 'Demo',
            summary: 'What is inside',
            icon: Icons.tune,
            children: [Text('inside')],
          ),
        ));
    await tester.pumpWidget(page(false, 0));
    expect(find.text('inside'), findsNothing);
    await tester.tap(find.text('Demo'));
    await tester.pumpAndSettle();
    expect(find.text('inside'), findsOneWidget);

    await tester.pumpWidget(page(false, 1));
    await tester.pumpAndSettle();
    expect(find.text('inside'), findsNothing);
    await tester.pumpWidget(page(true, 2));
    await tester.pumpAndSettle();
    expect(find.text('inside'), findsOneWidget);
  });

  testWidgets('the logs card offers the viewer and the time zone, and says '
      'when the zone changes', (tester) async {
    String? saved;
    await tester.pumpWidget(_host(AppLogsSettingsSection(
      logLocation: r'C:\logs',
      config: LogViewerConfig(
        appName: 'Test',
        version: '1.0.0',
        sources: const [],
        timeZoneId: 'utc',
        onTimeZoneChanged: (id) => saved = id,
      ),
    )));
    await tester.tap(find.text('Application logs'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('kit_view_logs')), findsOneWidget);
    expect(find.byKey(const ValueKey('kit_open_log_folder')), findsOneWidget);
    expect(find.text('UTC'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('kit_log_time_zone')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('UTC-08:00').last);
    await tester.pumpAndSettle();
    expect(saved, 'utc-480');
  });

  testWidgets('first-run setup starts on the desktop theme and applies it',
      (tester) async {
    FirstRunSetupDialog.pathsExistForTest = true;
    addTearDown(() => FirstRunSetupDialog.pathsExistForTest = null);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    ThemeMode? applied;
    String where = r'C:\data';
    var finished = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => FirstRunSetupDialog(
              appName: 'Test',
              themeMode: ThemeMode.light,
              onThemeMode: (m) => applied = m,
              paths: [
                FirstRunPath(
                  label: 'Data folder',
                  value: () => where,
                  isFolder: true,
                  onChanged: (v) => where = v,
                ),
              ],
              onFinish: () async => finished = true,
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(applied, ThemeMode.dark);
    expect(find.text(r'C:\data'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('kit_first_run_finish')));
    await tester.pumpAndSettle();
    expect(finished, isTrue);
    expect(find.byKey(const ValueKey('kit_first_run_setup')), findsNothing);
  });
}
