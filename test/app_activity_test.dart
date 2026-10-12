import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_activity.dart';
import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/json_editor_view.dart';

/// The app pauses while away; the Raw JSON header fits a narrow window.
void main() {
  test('away while hidden or locked, and back', () {
    final a = AppActivity.instance;
    var heard = 0;
    void listener() => heard++;
    a.addListener(listener);
    expect(AppActivity.away, isFalse);
    a.setLocked(true);
    expect(AppActivity.away, isTrue);
    a.setHidden(true);
    a.setLocked(false);
    expect(AppActivity.away, isTrue, reason: 'still minimized');
    a.setHidden(false);
    expect(AppActivity.away, isFalse);
    expect(heard, 2, reason: 'once away, once back');
    a.removeListener(listener);
  });

  testWidgets('the Raw JSON header fits a narrow window', (tester) async {
    tester.view.physicalSize = const Size(660, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = AppStateProvider(autoLoadSettings: false);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: p,
      child: const MaterialApp(home: Scaffold(body: JsonEditorView())),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Raw Config.json Editor'), findsOneWidget);
    p.dispose();
  });
}
