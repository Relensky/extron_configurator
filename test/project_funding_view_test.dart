import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/project_funding_view.dart';

/// The Priorities and funding card: folding, sorting and room totals.
void main() {
  Future<AppStateProvider> pump(WidgetTester tester) async {
    final provider = AppStateProvider(autoLoadSettings: false);
    provider.newProject(name: 'Refresh');
    provider.addProjectManualRoomList(
      'BSS 103\tDept\t5000\n'
      'ARTS 105\tDept\t9000',
      groupsArePriorities: true,
    );
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: ProjectFundingCard()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return provider;
  }

  double top(WidgetTester tester, String text) =>
      tester.getTopLeft(find.text(text)).dy;

  testWidgets('the budget figures fold away', (tester) async {
    await pump(tester);
    expect(find.text('Set aside for rooms'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('funding_figures_toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Set aside for rooms'), findsNothing);
    // The rooms are still there.
    expect(find.text('BSS 103'), findsOneWidget);
  });

  testWidgets('a priority folds its rooms away', (tester) async {
    final provider = await pump(tester);
    final p = provider.project.manualRooms.first.priority;
    await tester.tap(find.byKey(ValueKey('funding_fold_$p')));
    await tester.pumpAndSettle();
    expect(find.text('BSS 103'), findsNothing);
    await tester.tap(find.byKey(ValueKey('funding_fold_$p')));
    await tester.pumpAndSettle();
    expect(find.text('BSS 103'), findsOneWidget);
  });

  testWidgets('rooms sort by name', (tester) async {
    await pump(tester);
    expect(top(tester, 'BSS 103'), lessThan(top(tester, 'ARTS 105')));
    await tester.tap(find.byKey(const ValueKey('funding_sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name').last);
    await tester.pumpAndSettle();
    expect(top(tester, 'ARTS 105'), lessThan(top(tester, 'BSS 103')));
  });

  testWidgets('a line item shows its cost beside its budget', (tester) async {
    final provider = await pump(tester);
    final line = provider.project.manualRooms.first;
    final total = find.byKey(ValueKey('funding_total_${line.id}'));
    expect(total, findsOneWidget);
    final text = tester.widget<Text>(total).data!;
    expect(
      text,
      line.replacementCost > 0 ? contains('5,000') : '-',
    );
  });
}
