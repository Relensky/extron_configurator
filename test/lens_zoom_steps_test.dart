import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_flow_overview.dart';

void main() {
  test('the magnifier zoom steps up and down and stops at the ends', () {
    expect(nextLensZoom(1.0, up: true), 1.5);
    expect(nextLensZoom(1.0, up: false), 0.75);
    // An in-between auto zoom goes to the step beside it.
    expect(nextLensZoom(1.2, up: true), 1.5);
    expect(nextLensZoom(1.2, up: false), 1.0);
    expect(nextLensZoom(kLensZooms.last, up: true), kLensZooms.last);
    expect(nextLensZoom(kLensZooms.first, up: false), kLensZooms.first);
    expect(autoLensZoom(0.1), 1.0);
    expect(autoLensZoom(0.8), 1.6);
  });
}
