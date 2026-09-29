import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_device_library.dart';

/// "Yours" means an entry somebody added in the app, not every entry the
/// catalog file ships with.
void main() {
  AvDeviceLibrary withShipped() {
    final library = AvDeviceLibrary.empty();
    library.applyDoc({
      'entries': [
        {'model': 'AP7900B', 'price': 900, 'custom': true, 'ports': []},
      ],
    });
    return library;
  }

  test('a catalog entry is a system entry', () {
    final t = withShipped().templateForModel('AP7900B')!;
    expect(t.custom, isTrue, reason: 'still written back on save');
    expect(t.addedByUser, isFalse);
  });

  test('a new entry is yours, and stays yours through a save', () {
    final library = withShipped();
    library.upsert(const AvDeviceTemplate(model: 'SX-DPP-999', ports: []));
    final t = library.templateForModel('SX-DPP-999')!;
    expect(t.addedByUser, isTrue);
    final back = AvDeviceTemplate.fromJson(t.toJson(), custom: true);
    expect(back.addedByUser, isTrue);
  });

  test('editing a system entry does not make it yours', () {
    final library = withShipped();
    final t = library.templateForModel('AP7900B')!;
    library.upsert(t.copyWith(price: 950));
    expect(library.templateForModel('AP7900B')!.addedByUser, isFalse);
    // Nor does renaming it.
    library.upsert(
      library.templateForModel('AP7900B')!.copyWith(model: 'AP7900B-2'),
      previousModel: 'AP7900B',
    );
    expect(library.templateForModel('AP7900B-2')!.addedByUser, isFalse);
  });

  test('editing your own entry keeps it yours', () {
    final library = withShipped();
    library.upsert(const AvDeviceTemplate(model: 'Mine 1', ports: []));
    library.upsert(
      library.templateForModel('Mine 1')!.copyWith(price: 10),
    );
    expect(library.templateForModel('Mine 1')!.addedByUser, isTrue);
  });
}
