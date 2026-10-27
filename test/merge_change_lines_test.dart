import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/collab/merge_labels.dart';

/// A combine says exactly what changed, not "500 items, now 501".
void main() {
  test('a long list names the one row added and the one changed', () {
    final before = [
      for (var i = 0; i < 500; i++) {'id': 'p$i', 'name': 'Part $i', 'qty': 1},
    ];
    final after = [
      for (final r in before)
        r['id'] == 'p7' ? {...r, 'qty': 3} : r,
      {'id': 'p500', 'name': 'Part 500', 'qty': 2},
    ];
    expect(
      describeMergeChange(before, after).split('\n'),
      ['"Part 7" > Quantity: 1 -> 3', 'added "Part 500"'],
    );
  });

  test('a removed row and a changed field of a row', () {
    expect(
      describeMergeChange(
        {'name': 'BSS 103', 'notes': 'old', 'gone': 'x'},
        {'name': 'BSS 103', 'notes': 'new'},
      ).split('\n'),
      ['Notes: old -> new', 'Gone: removed (was x)'],
    );
    expect(
      describeMergeChange(
        [
          {'id': 'a', 'name': 'One'},
          {'id': 'b', 'name': 'Two'},
        ],
        [
          {'id': 'a', 'name': 'One'},
        ],
      ),
      'removed "Two"',
    );
  });

  test('plain values and lists without ids', () {
    expect(describeMergeChange('a', 'b'), 'a -> b');
    expect(describeMergeChange(['x', 'y', 'y'], ['x', 'y', 'z']).split('\n'),
        ['added z', 'removed y']);
    expect(describeMergeChange(['x', 'y'], ['y', 'x']), 'reordered');
    expect(describeMergeChange(null, 'b'), 'added: b');
    expect(describeMergeChange('a', null), 'removed (was a)');
  });
}
