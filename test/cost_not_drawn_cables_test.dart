import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';

/// Cable the job needs that is not on the drawing is its own count, and its
/// spares are their own count on top.
void main() {
  test('a not-drawn cable keeps its spares separate', () {
    final p = AppStateProvider(autoLoadSettings: false);
    p.roomConfig['SYSTEM_SETUP'] = <String, dynamic>{};
    p.setAvCostIncludeCabling(true);
    final item = p.addAvCostExtraCable(description: 'Cat6A patch', qty: 3);
    p.setAvEquipmentSpares(item.id, 2);

    final line = p.roomCost.cabling.singleWhere((l) => l.key == item.id);
    expect(line.qty, 5);
    expect(p.avEquipmentSpares(item.id), 2);

    // Taken off the job, its spares go with it.
    p.removeAvCostExtraCable(item.id);
    expect(p.avEquipmentSpares(item.id), 0);
  });
}
