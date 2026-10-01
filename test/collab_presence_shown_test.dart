import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/collab/collab_widgets.dart';
import 'package:extron_configurator/collab/presence.dart';

/// Somebody is shown as editing only once they have changed something.
void main() {
  final opened = DateTime(2026, 9, 30, 9);

  EditorPresence person({bool unsaved = false, DateTime? savedAt}) =>
      EditorPresence(
        user: 'jsmith',
        machine: 'PC1',
        since: opened,
        heartbeat: opened.add(const Duration(minutes: 5)),
        unsaved: unsaved,
        savedAt: savedAt,
      );

  test('just having the file open is not editing it', () {
    expect(collabHasChanged(person()), isFalse);
  });

  test('unsaved changes are', () {
    expect(collabHasChanged(person(unsaved: true)), isTrue);
  });

  test('so is a save made since opening', () {
    expect(
      collabHasChanged(
        person(savedAt: opened.add(const Duration(minutes: 3))),
      ),
      isTrue,
    );
  });
}
