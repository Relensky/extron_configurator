import 'package:extron_configurator/collab/collab_controller.dart';
import 'package:extron_configurator/collab/collab_widgets.dart';
import 'package:extron_configurator/collab/json_merge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// The share brings many places changed on both sides: one button takes the
/// share's for all of them, but Combine is still pressed by a person.
void main() {
  const conflicts = [
    MergeConflict(path: 'rooms[id=a].budget', base: 1, mine: 2, theirs: 3),
    MergeConflict(path: 'rooms[id=b].budget', base: 1, mine: 4, theirs: 5),
    MergeConflict(path: 'rooms[id=c].budget', base: 1, mine: 6, theirs: 7),
  ];

  Future<Map<String, MergeSide>?> open(WidgetTester tester) async {
    Map<String, MergeSide>? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showMergeConflictDialog(
            context,
            kind: CollabDocKind.project,
            conflicts: conflicts,
            who: 'The share',
          ),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Take all from the share'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('collab_conflict_all_theirs')));
    await tester.pump();
    // Nothing combined yet.
    expect(result, isNull);
    await tester.tap(find.byKey(const ValueKey('collab_conflict_apply')));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('Take all from the share chooses the share for every place',
      (tester) async {
    final result = await open(tester);
    expect(result, {for (final c in conflicts) c.path: MergeSide.theirs});
  });
}
