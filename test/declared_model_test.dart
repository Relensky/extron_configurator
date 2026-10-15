import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';

void main() {
  const declared = [
    'ShareLink Pro 2000',
    'ShareLink Pro 1100',
    'SMP 351',
    'SMP 351 3G-SDI',
    'IN1608',
  ];

  String? find(String model) =>
      AppStateProvider.declaredModelFor(model, declared);

  test('the same name however it is capitalized', () {
    expect(find('sharelink pro 2000'), 'ShareLink Pro 2000');
  });

  test('a kit of a listed model is that model', () {
    expect(find('ShareLink Pro 2000 Miracast & ShareNext US'),
        'ShareLink Pro 2000');
    expect(find('ShareLink Pro 1100 Miracast Kit EU'), 'ShareLink Pro 1100');
  });

  test('the longest listed model wins', () {
    expect(find('SMP 351 3G-SDI - 80 GB SSD'), 'SMP 351 3G-SDI');
    expect(find('SMP 351 - 80 GB SSD'), 'SMP 351');
  });

  test('never mid-word, and nothing for an unknown product', () {
    expect(find('IN16080'), isNull);
    expect(find('ShareLink Pro 20000'), isNull);
    expect(find('DMP 128 Plus'), isNull);
    expect(find(''), isNull);
  });
}
