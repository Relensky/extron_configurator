import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/collab/json_merge.dart';
import 'package:extron_configurator/collab/merge_labels.dart';

/// Two people's work, combined without either losing any.
void main() {
  Map<String, dynamic> todo(String id, String text, {String roomId = ''}) => {
    'id': id,
    'text': text,
    'state': 'open',
    if (roomId.isNotEmpty) 'roomId': roomId,
  };

  group('two people adding at once', () {
    test('both new notes are kept, though both were numbered todo2', () {
      final base = {
        'todos': [todo('todo1', 'existing')],
        'todoCounter': 1,
      };
      final mine = {
        'todos': [todo('todo1', 'existing'), todo('todo2', 'ring the dean')],
        'todoCounter': 2,
      };
      final theirs = {
        'todos': [todo('todo1', 'existing'), todo('todo2', 'order cables')],
        'todoCounter': 2,
      };

      final r = mergeJson3(base, mine, theirs);
      expect(r.conflicts, isEmpty, reason: 'nothing to choose between');
      expect(r.renumbered, 1);
      final todos = (r.merged as Map)['todos'] as List;
      final byId = {
        for (final t in todos) (t as Map)['id']: t['text'],
      };
      expect(byId, {
        'todo1': 'existing',
        'todo2': 'ring the dean',
        'todo3': 'order cables',
      });
    });

    test('what pointed at their new row follows it to its new number', () {
      final base = {'rooms': <Map>[], 'todos': <Map>[]};
      final mine = {
        'rooms': [
          {'id': 'room1', 'label': 'HOLT 170'},
        ],
        'todos': <Map>[],
      };
      final theirs = {
        'rooms': [
          {'id': 'room1', 'label': 'ARTS 111'},
        ],
        'todos': [todo('todo1', 'check ARTS', roomId: 'room1')],
      };

      final r = mergeJson3(base, mine, theirs);
      final merged = r.merged as Map;
      final rooms = merged['rooms'] as List;
      expect(rooms, hasLength(2));
      final arts = rooms.firstWhere((x) => (x as Map)['label'] == 'ARTS 111');
      expect((arts as Map)['id'], 'room2');
      // Their note still names their room, not mine.
      expect(((merged['todos'] as List).single as Map)['roomId'], 'room2');
    });

    test('the same row added the same way by both is kept once', () {
      final base = {'todos': <Map>[]};
      final same = {
        'todos': [todo('todo1', 'same')],
      };
      final r = mergeJson3(base, same, same);
      expect((r.merged as Map)['todos'], hasLength(1));
      expect(r.renumbered, 0);
    });

    test('a row keyed on a model is the same thing, merged field by field', () {
      final base = {'items': <Map>[]};
      final mine = {
        'items': [
          {'model': 'DTP2 T 211', 'qty': 2},
        ],
      };
      final theirs = {
        'items': [
          {'model': 'DTP2 T 211', 'note': 'spare'},
        ],
      };
      final r = mergeJson3(base, mine, theirs);
      expect((r.merged as Map)['items'], [
        {'model': 'DTP2 T 211', 'qty': 2, 'note': 'spare'},
      ]);
    });
  });

  group('keep both', () {
    final base = {
      'todos': [todo('todo1', 'call Extron')],
    };
    final mine = {
      'todos': [todo('todo1', 'call Extron about DTP')],
    };
    final theirs = {
      'todos': [todo('todo1', 'call Extron - Tuesday')],
    };

    test('two texts are kept one after the other', () {
      final r = mergeJson3(base, mine, theirs, resolve: (_) => MergeSide.both);
      expect(r.conflicts.single.canKeepBoth, isTrue);
      expect(
        (((r.merged as Map)['todos'] as List).single as Map)['text'],
        'call Extron about DTP / call Extron - Tuesday',
      );
    });

    test('a note one deleted and the other changed is kept, changed', () {
      final deleted = {'todos': <Map>[]};
      final r = mergeJson3(
        base,
        deleted,
        theirs,
        resolve: (_) => MergeSide.both,
      );
      expect(r.conflicts.single.canKeepBoth, isTrue);
      expect(
        (((r.merged as Map)['todos'] as List).single as Map)['text'],
        'call Extron - Tuesday',
      );
    });
  });

  group('naming the place', () {
    test('a note is named by what it says', () {
      final doc = {
        'todos': [todo('todo7', 'chase Extron on the DTP lead time')],
      };
      expect(
        describeMergePlace('todos[id=todo7].text', doc),
        'Job list > "chase Extron on the DTP lead time" > Text',
      );
      expect(describeMergePlace('budgetLines', doc), 'Budget');
      expect(describeMergePlace('someNewThing', doc), 'Some new thing');
      expect(describeMergeValue(null), 'deleted');
    });
  });
}
