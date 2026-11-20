import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/collapsible_bar.dart';
import 'package:extron_configurator/form_factor.dart';
import 'package:extron_configurator/project_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

/// iPad and iPhone: the job's details fold to one line, and stay folded as
/// the panes are switched until they are opened again.
void main() {
  testWidgets('folded job details stay folded from pane to pane',
      (tester) async {
    debugMobileDevice = true;
    addTearDown(() {
      debugMobileDevice = null;
      BarFolds.setFolded('project_details', false);
    });
    final p = AppStateProvider(autoLoadSettings: false)
      ..settingsLoaded = true
      ..firstRunSetupNeeded = false;
    p.newProject(name: 'Arts');
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<AppStateProvider>.value(
      value: p,
      child: const MaterialApp(home: Scaffold(body: ProjectView())),
    ));
    await tester.pumpAndSettle();

    final stakeholder = find.widgetWithText(TextField, 'Stakeholder');
    expect(stakeholder, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('project_details_hide')));
    await tester.pumpAndSettle();
    expect(stakeholder, findsNothing);
    expect(find.byKey(const ValueKey('project_details_show')), findsOneWidget);

    for (final pane in ['plans', 'timeline', 'rooms']) {
      await tester.tap(find.byKey(ValueKey('project_pane_$pane')).first,
          warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(stakeholder, findsNothing, reason: 'folded on $pane');
    }

    await tester.tap(find.byKey(const ValueKey('project_details_show')));
    await tester.pumpAndSettle();
    expect(stakeholder, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
