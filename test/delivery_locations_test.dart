import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/delivery_locations.dart';

/// ============================================================================
///  THE PLACES KIT GOES
/// ============================================================================
///  A loading dock is a fact about the estate, not about one job, so the list
///  of them is a shared file rather than something retyped per delivery. What
///  is guarded here:
///
///    * the file round-trips, and a hand-edited one still reads
///    * a place says what it is FOR, so a dock is not offered as a shelf
///    * the picker offers the saved list first and the job's own history after
///    * moving several lots at once records where each one moved FROM
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('delivery_places_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('the list itself', () {
    test('a place is added, found by name, and reordered', () {
      final book = DeliveryLocationBook();
      final dock = book.add(name: 'MLIB loading dock', address: '1 Campus Dr');
      book.add(name: 'Central Stores');

      expect(dock, isNotNull);
      expect(book.count, 2);
      // Ignoring case is the only spelling difference worth forgiving on a
      // name somebody types into a box.
      expect(book.byName('mlib LOADING dock')?.id, dock!.id);
      expect(book.byName('nowhere'), isNull);

      book.move(book.places.last.id, up: true);
      expect(book.places.first.name, 'Central Stores');
    });

    test('a nameless place is refused - it would write nothing on a row', () {
      final book = DeliveryLocationBook();
      expect(book.add(name: '   '), isNull);
      expect(book.isEmpty, isTrue);
    });

    test('what a place is for decides where it is offered', () {
      final book = DeliveryLocationBook();
      book.add(name: 'Dock', use: DeliveryLocationUse.delivery);
      book.add(name: 'Basement', use: DeliveryLocationUse.storage);
      book.add(name: 'Stores', use: DeliveryLocationUse.both);

      expect(
        [for (final p in book.forUse(storage: false)) p.name],
        ['Dock', 'Stores'],
      );
      expect(
        [for (final p in book.forUse(storage: true)) p.name],
        ['Basement', 'Stores'],
      );
    });

    test('the detail line is never blank', () {
      final book = DeliveryLocationBook();
      final bare = book.add(name: 'Dock', use: DeliveryLocationUse.delivery)!;
      expect(bare.detail, DeliveryLocationUse.delivery.phrase);

      final noted = book.add(name: 'Cage', notes: 'ring ahead')!;
      expect(noted.detail, 'ring ahead');

      final addressed = book.add(name: 'Stores', address: '1 Campus Dr')!;
      expect(addressed.detail, '1 Campus Dr');
    });
  });

  group('the file', () {
    test('every field survives a save and a load', () async {
      final path = '${dir.path}/delivery_locations.json';
      final book = DeliveryLocationBook();
      book.add(
        name: 'MLIB 031',
        address: 'Library basement',
        use: DeliveryLocationUse.storage,
        notes: 'keys from the front desk',
      );
      expect(await book.save(toPath: path), path);

      final read = await DeliveryLocationBook.load(path);
      final place = read.places.single;
      expect(place.name, 'MLIB 031');
      expect(place.address, 'Library basement');
      expect(place.use, DeliveryLocationUse.storage);
      expect(place.notes, 'keys from the front desk');
      expect(read.filePath, path);
    });

    test('no file is an empty list, not an error', () async {
      final book = await DeliveryLocationBook.load('${dir.path}/nothing.json');
      expect(book.isEmpty, isTrue);
      expect(book.source, contains('No places saved yet'));
    });

    test('a hand-written file reads without ids, and a broken one is empty',
        () async {
      final good = '${dir.path}/hand.json';
      File(good).writeAsStringSync(
        jsonEncode({
          'locations': [
            {'name': 'Bessey dock'},
            {'name': 'Bessey dock two', 'use': 'nonsense'},
            {'name': '   '},
          ],
        }),
      );
      final book = await DeliveryLocationBook.load(good);
      expect(book.count, 2, reason: 'the nameless row is not a place');
      expect(book.places.first.id, isNotEmpty);
      // A use this build does not know still gets offered, on both sides.
      expect(book.places.last.use, DeliveryLocationUse.both);

      final bad = '${dir.path}/broken.json';
      File(bad).writeAsStringSync('{ not json');
      final broken = await DeliveryLocationBook.load(bad);
      expect(broken.isEmpty, isTrue);
      expect(broken.source, contains('Failed to load'));
    });
  });

  group('what the picker offers', () {
    test('the saved places come first, then what this job typed', () {
      final book = DeliveryLocationBook();
      book.add(name: 'Central Stores', address: '1 Campus Dr');
      book.add(name: 'MLIB 031', use: DeliveryLocationUse.storage);

      final choices = deliveryPlaceChoices(
        book: book,
        usedOnThisJob: const ['A contractor warehouse', 'central stores'],
        storage: true,
      );

      // Central Stores is offered on both sides - it is a place gear can be
      // dropped at AND left at - so it survives a storage question, and the
      // spelling the job typed does not appear a second time under it.
      expect([for (final c in choices) c.name], [
        'Central Stores',
        'MLIB 031',
        'A contractor warehouse',
      ]);
      expect(choices.first.saved, isTrue);
      expect(choices.last.saved, isFalse);
      expect(choices.last.detail, 'Used on this job');
    });

    test('a place on both lists is offered once', () {
      final book = DeliveryLocationBook();
      book.add(name: 'Central Stores');
      final choices = deliveryPlaceChoices(
        book: book,
        usedOnThisJob: const ['CENTRAL STORES'],
        storage: false,
      );
      expect(choices.length, 1);
      expect(choices.single.saved, isTrue);
    });

    test('the provider merges the shared list with the open job', () {
      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject(name: 'Bessey Hall');
      p.deliveryLocations.add(name: 'Central Stores');
      p.addProjectDelivery(itemName: 'Wall plate', location: 'Bessey dock');

      expect(
        [for (final c in p.deliveryPlacesFor(storage: false)) c.name],
        ['Central Stores', 'Bessey dock'],
      );
    });
  });

  group('moving several lots at once', () {
    ({AppStateProvider provider, List<String> ids}) job() {
      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject(name: 'Bessey Hall');
      final a = p.addProjectDelivery(
        itemName: 'Wall plate',
        qty: 6,
        location: 'Bessey loading dock',
      );
      final b = p.addProjectDelivery(
        itemName: 'Ceiling mount',
        qty: 3,
        location: 'Bessey loading dock',
      );
      return (provider: p, ids: [a.id, b.id]);
    }

    test('they all land in one place, and each says where it came from', () {
      final j = job();
      final moved = j.provider.moveProjectDeliveries(
        j.ids,
        state: DeliveryState.stored,
        location: 'MLIB 031',
      );
      expect(moved, 2);

      for (final id in j.ids) {
        final row = j.provider.project.deliveryById(id)!;
        expect(row.state, DeliveryState.stored);
        expect(row.location, 'MLIB 031');
        // THE POINT OF THE WHOLE THING: the row still says where it had been,
        // signed and timed, after the location has been overwritten.
        final note = row.notes.single;
        expect(
          note.text,
          'Moved from On site - Bessey loading dock to In storage - MLIB 031.',
        );
        expect(note.at, isNotNull);
      }

      // And the job's history carries the same sentence.
      final logged = j.provider.project.history
          .where((h) => h.summary.startsWith('moved from'))
          .toList();
      expect(logged.length, 2);
    });

    test('the arrival date is left alone; the install date is set', () {
      final j = job();
      final arrived = j.provider.project.deliveryById(j.ids.first)!.deliveredOn;

      j.provider.moveProjectDeliveries(
        j.ids,
        state: DeliveryState.installed,
        on: DateTime(2026, 6, 4),
      );

      final row = j.provider.project.deliveryById(j.ids.first)!;
      expect(row.deliveredOn, arrived, reason: 'a move is not an arrival');
      expect(row.installedOn, DateTime(2026, 6, 4));
      // The place it was held is kept, exactly as a single move keeps it.
      expect(row.location, 'Bessey loading dock');
      expect(
        row.notes.single.text,
        'Moved from On site - Bessey loading dock to Installed.',
      );
    });

    test('a row that would not change is skipped rather than stamped', () {
      final j = job();
      j.provider.moveProjectDeliveries(
        j.ids,
        state: DeliveryState.stored,
        location: 'MLIB 031',
      );
      final again = j.provider.moveProjectDeliveries(
        j.ids,
        state: DeliveryState.stored,
        location: 'MLIB 031',
      );

      expect(again, 0);
      expect(j.provider.project.deliveryById(j.ids.first)!.notes.length, 1);
    });

    test('anything extra typed goes on the note with the move', () {
      final j = job();
      j.provider.moveProjectDeliveries(
        [j.ids.first],
        state: DeliveryState.stored,
        location: 'MLIB 031',
        note: 'two boxes water damaged',
      );
      expect(
        j.provider.project.deliveryById(j.ids.first)!.notes.single.text,
        'Moved from On site - Bessey loading dock to In storage - MLIB 031. '
        'two boxes water damaged',
      );
    });

    test('an id that has gone is skipped rather than throwing', () {
      final j = job();
      expect(
        j.provider.moveProjectDeliveries(
          ['del999'],
          state: DeliveryState.stored,
          location: 'MLIB 031',
        ),
        0,
      );
    });
  });
}
