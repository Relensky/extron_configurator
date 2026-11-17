import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/collab/combine_details.dart';
import 'package:extron_configurator/collab/json_merge.dart';
import 'package:extron_configurator/collab/merge_labels.dart';

/// A combine names who changed what, item by item - not "500 items".
Map<String, dynamic> _entry(int i,
        {String item = 'Cost',
        String field = 'Drawing',
        String summary = '',
        String name = 'Derek Stanley',
        String user = 'dstanley',
        String machine = 'DSNPC3'}) =>
    {
      'itemKey': 'drawing:cost',
      'itemName': item,
      'field': field,
      'summary': summary.isEmpty ? 'Edit $i' : summary,
      'user': user,
      'at': DateTime(2026, 11, 1).add(Duration(minutes: i)).toIso8601String(),
      if (name.isNotEmpty) 'name': name,
      'machine': machine,
    };

void main() {
  group('a history kept to 500 entries', () {
    final base = [for (var i = 0; i < 500; i++) _entry(i)];

    test('their new entries come in one by one, not as a conflict', () {
      final mine = [...base.sublist(1), _entry(1000, summary: 'Mine')];
      final theirs = [
        ...base.sublist(2),
        _entry(2000, item: 'AV Flow', summary: 'Draw cable', name: 'Nicole'),
        _entry(2001, summary: 'Add MXW neXt 2', name: 'Nicole'),
      ];
      final r = mergeJson3({'history': base}, {'history': mine},
          {'history': theirs});
      expect(r.conflicts, isEmpty);
      final merged = (r.merged as Map)['history'] as List;
      // Both drops stand, mine then theirs after.
      expect(merged.first, base[2]);
      expect([for (final e in merged.skip(497)) e['summary']],
          ['Edit 499', 'Mine', 'Draw cable', 'Add MXW neXt 2']);
      expect(r.changes.map((c) => c.key), ['history#1', 'history#2']);
    });

    test('a declined entry is left out', () {
      final theirs = [...base.sublist(1), _entry(2000, summary: 'Theirs')];
      final r = mergeJson3({'h': base}, {'h': base}, {'h': theirs},
          declined: {'h#1'});
      final merged = (r.merged as Map)['h'] as List;
      expect(merged.any((e) => e['summary'] == 'Theirs'), isFalse);
    });

    test('a list that is not a log still conflicts', () {
      final rows = [
        for (var i = 0; i < 3; i++) {'name': 'Same', 'qty': i},
      ];
      final r = mergeJson3({'l': rows}, {'l': [...rows.sublist(1), rows[0]]},
          {'l': rows.sublist(1)});
      expect(r.conflicts, hasLength(1));
    });
  });

  group('each history entry is its own line', () {
    test('grouped by the room or document, named by who and what', () {
      final e = _entry(5,
          item: 'PAC 134 - Config',
          field: 'Saved',
          summary: 'to disk, with the AV flow',
          name: 'Michelle',
          machine: 'G02190');
      final place = describeMergeChangePlace('history', null, e, const {});
      expect(place,
          'History > PAC 134 - Config > Michelle on G02190: Saved: to disk, '
          'with the AV flow');
      expect(mergePlaceGroup(place), 'History > PAC 134 - Config');
      expect(describeMergeChangeLine(null, e),
          startsWith('added to the history 2026-11-01'));
    });

    test('a room history is grouped by tab: Cost, AV Flow', () {
      final doc = {'config': {}, 'av': {'roomHistory': []}};
      final cost = describeMergeChangePlace(
          'av.roomHistory', null, _entry(1, summary: 'Add PS 1215 C'), doc);
      final flow = describeMergeChangePlace('av.roomHistory', null,
          _entry(2, item: 'AV Flow', summary: 'Draw cable'), doc);
      expect(mergePlaceGroup(cost), 'Room history > Cost');
      expect(mergePlaceLeaf(cost), 'Derek Stanley on DSNPC3: Add PS 1215 C');
      expect(mergePlaceGroup(flow), 'Room history > AV Flow');
    });

    test('no name falls back to the login', () {
      expect(describeHistoryEntry(_entry(1, name: '', summary: 'Move')),
          'dstanley on DSNPC3: Move');
      expect(describeMergeValue(_entry(1, summary: 'Move')),
          'Derek Stanley on DSNPC3: Move');
    });
  });

  test('a room drawing change is named by its tab', () {
    final doc = {
      'config': {},
      'av': {
        'cost': {
          'items': [
            {'id': 'i1', 'description': 'Sony 75" display', 'qty': 1},
          ],
        },
        'nodes': [
          {'id': 'n1', 'label': 'Projector'},
        ],
      },
    };
    expect(describeMergePlace('av.cost.items[id=i1].qty', doc),
        'Cost > Items > "Sony 75" display" > Quantity');
    expect(describeMergePlace('av.nodes[id=n1].x', doc),
        'AV Flow > Drawing > "Projector" > X');
  });

  test('a delivery is named by its item', () {
    expect(describeMergeValue({'id': 'del6', 'itemName': '1 x Projector'}),
        '"1 x Projector"');
  });
}
