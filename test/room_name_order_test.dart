import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';

/// Rooms listed the way a person reads them.
void main() {
  test('numbers sort as numbers, letters after the same number', () {
    final rooms = [
      'THMA 116',
      'arts 306A',
      'ARTS 9',
      'ARTS 306',
      'AJH 125B',
      'ARTS 105',
      'AJH 125A',
    ]..sort(compareRoomNames);
    expect(rooms, [
      'AJH 125A',
      'AJH 125B',
      'ARTS 9',
      'ARTS 105',
      'ARTS 306',
      'arts 306A',
      'THMA 116',
    ]);
  });
}
