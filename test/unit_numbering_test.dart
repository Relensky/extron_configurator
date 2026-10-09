import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/unit_numbering.dart';

List<({String id, String label})> units(List<String> labels) => [
  for (var i = 0; i < labels.length; i++) (id: 'N${i + 1}', label: labels[i]),
];

void main() {
  test('units sharing a name are numbered in drawing order', () {
    expect(sequentialUnitNames(units(['SX-DPP-102', 'SX-DPP-102'])), {
      'N1': 'SX-DPP-102 1',
      'N2': 'SX-DPP-102 2',
    });
  });

  test('a model number on the end is not taken for a count', () {
    expect(sharedUnitBase(['USB-C HD 101', 'USB-C HD 101']), 'USB-C HD 101');
    expect(sequentialUnitNames(units(['USB-C HD 101', 'USB-C HD 101'])), {
      'N1': 'USB-C HD 101 1',
      'N2': 'USB-C HD 101 2',
    });
  });

  test('the numbers already there are kept; a new unit goes on the end', () {
    expect(
      sequentialUnitNames(units(['Display 3', 'Display 1', 'Display'])),
      {'N3': 'Display 4'},
    );
    // Config blocks 4 and 5 keep their numbers.
    expect(sequentialUnitNames(units(['Screen 4', 'Screen 5'])), isEmpty);
    expect(
      sequentialUnitNames(units(['Screen 4', 'Screen 5', 'Screen 5'])),
      {'N3': 'Screen 6'},
    );
  });

  test('the other of a pair taken off, a "1" goes back to its name', () {
    expect(soleUnitName('Cam570 1', 'Cam570 2'), 'Cam570');
    expect(soleUnitName('Screen 4', 'Screen 5'), isNull);
    expect(soleUnitName('Projector 1', 'Lobby display'), isNull);
  });

  test('the line name is the base, over the units shared name', () {
    expect(
      sequentialUnitNames(
        units(['SX-DPP-102', 'SX-DPP-102']),
        lineName: 'Network PDU TV',
      ),
      {'N1': 'Network PDU TV 1', 'N2': 'Network PDU TV 2'},
    );
  });

  test('the first of the series takes 1, whatever came after it', () {
    expect(
      sequentialUnitNames(units(['Display', 'Display 2', 'Display 3'])),
      {'N1': 'Display 1'},
    );
    expect(
      sequentialUnitNames(units(['Display', 'Display 1', 'Display 2'])),
      {'N1': 'Display 1', 'N2': 'Display 2', 'N3': 'Display 3'},
    );
    // Added after the series: on the end.
    expect(
      sequentialUnitNames(units(['Display 1', 'Display 2', 'Display'])),
      {'N3': 'Display 3'},
    );
  });

  test('a unit with a name of its own is left out', () {
    expect(
      sequentialUnitNames(units(['Display', 'Lobby display', 'Display'])),
      {'N1': 'Display 1', 'N3': 'Display 2'},
    );
    expect(sequentialUnitNames(units(['Left PDU', 'Right PDU'])), isEmpty);
  });

  test('a new line name keeps each unit its number', () {
    expect(
      sequentialUnitNames(units(['PDU 1', 'PDU 3']), lineName: 'Surge'),
      {'N1': 'Surge 1', 'N2': 'Surge 3'},
    );
  });

  test('one unit, or names already in order, change nothing', () {
    expect(sequentialUnitNames(units(['Display'])), isEmpty);
    expect(sequentialUnitNames(units(['Display 1', 'Display 2'])), isEmpty);
  });

  test('the unit to take off first is the highest-numbered', () {
    expect(
      lastNumberedUnit(units(['Display 1', 'Display 3', 'Display 2'])),
      'N2',
    );
    expect(lastNumberedUnit(units(['A', 'B'])), 'N2');
  });
}
