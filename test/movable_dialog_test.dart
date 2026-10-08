import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:extron_configurator/movable_dialog.dart';

void main() {
  testWidgets('a movable dialog follows a drag', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showMovableDialog<void>(
                context: context,
                builder: (_) => const AlertDialog(
                  title: Text('Projector'),
                  content: Text('Body'),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.text('Projector'));
    await tester.drag(find.text('Projector'), const Offset(-120, 80));
    await tester.pump();
    final after = tester.getTopLeft(find.text('Projector'));
    expect(after.dx, lessThan(before.dx - 100));
    expect(after.dy, greaterThan(before.dy + 60));
    expect(find.text('Body'), findsOneWidget);
  });
}
