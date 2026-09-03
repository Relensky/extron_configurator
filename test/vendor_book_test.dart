import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/project_view.dart';
import 'package:extron_configurator/vendor_book.dart';

/// ============================================================================
///  THE DEFAULT VENDOR LIST
/// ============================================================================
///  Who the shop asks to quote is a fact about the department, not about one
///  building, so the directory is a shared file every job starts from. What is
///  guarded here:
///
///    * the file round-trips, and a hand-edited one still reads
///    * a new job arrives with the companies already on its Packages tab
///    * an older job can take what it is missing, matched on the NAME, and
///      pressing it twice adds nothing the second time
///    * a job's own vendor is a COPY - editing it does not rewrite the share
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_vendor_book_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('the list itself', () {
    test('a company is added, found by name, and reordered', () {
      final book = VendorBook();
      final extron = book.add(name: 'Extron', contact: 'sales@extron');
      book.add(name: 'Shure');

      expect(extron, isNotNull);
      expect(book.count, 2);
      // Ignoring case is the only spelling difference worth forgiving on a
      // name somebody types into a box.
      expect(book.byName('  eXtRoN ')?.id, extron!.id);
      expect(book.byName('nobody'), isNull);

      book.move(book.vendors.last.id, up: true);
      expect(book.vendors.first.name, 'Shure');
    });

    test('a nameless company is refused - it would seed nothing', () {
      final book = VendorBook();
      expect(book.add(name: '   '), isNull);
      expect(book.isEmpty, isTrue);
    });

    test('the detail line is never blank', () {
      final book = VendorBook();
      expect(book.add(name: 'Extron')!.detail, 'On the shared list');
      expect(book.add(name: 'Shure', notes: 'account 4471')!.detail,
          'account 4471');
      expect(
        book.add(name: 'Biamp', contact: 'Dana at the rep')!.detail,
        'Dana at the rep',
      );
    });
  });

  group('the file', () {
    test('every field survives a save and a load', () async {
      final file = '${dir.path}/vendor_list.json';
      final book = VendorBook();
      book.add(
        name: 'Extron',
        contact: 'quotes@example',
        notes: 'account 4471, quotes exclude freight',
      );
      expect(await book.save(toPath: file), file);

      final read = await VendorBook.load(file);
      final vendor = read.vendors.single;
      expect(vendor.name, 'Extron');
      expect(vendor.contact, 'quotes@example');
      expect(vendor.notes, 'account 4471, quotes exclude freight');
      expect(read.filePath, file);
    });

    test('no file is an empty list, not an error', () async {
      final book = await VendorBook.load('${dir.path}/nothing.json');
      expect(book.isEmpty, isTrue);
      expect(book.source, contains('No vendors saved yet'));
    });

    test('a hand-written file reads without ids, and a broken one is empty',
        () async {
      final good = '${dir.path}/hand.json';
      File(good).writeAsStringSync(
        jsonEncode({
          'vendors': [
            {'name': 'Extron'},
            {'name': 'Shure', 'contact': 'the rep'},
            {'name': '   '},
          ],
        }),
      );
      final book = await VendorBook.load(good);
      expect(book.count, 2, reason: 'the nameless row is not a company');
      expect(book.vendors.first.id, isNotEmpty);

      final bad = '${dir.path}/broken.json';
      File(bad).writeAsStringSync('{ not json');
      final broken = await VendorBook.load(bad);
      expect(broken.isEmpty, isTrue);
      expect(broken.source, contains('Failed to load'));
    });
  });

  group('what a job starts with', () {
    AppStateProvider shop() {
      final p = AppStateProvider(autoLoadSettings: false);
      p.vendorBook.add(name: 'Extron', contact: 'quotes@example');
      p.vendorBook.add(name: 'Shure', notes: 'slow on small orders');
      return p;
    }

    test('a new job arrives with the shared directory on it', () {
      final p = shop();
      p.newProject(name: 'Bessey refresh');

      expect([for (final v in p.project.vendors) v.name], ['Extron', 'Shure']);
      expect(p.project.vendors.first.contact, 'quotes@example');
      // NOTHING HAS BEEN DONE YET. A job that opens already asking to be saved
      // is a job somebody saves before they have worked on it.
      expect(p.projectDirty, isFalse);
    });

    test('a job with no shared list behaves as it always did', () {
      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject(name: 'Bessey refresh');
      expect(p.project.vendors, isEmpty);
    });

    test('an older job takes what it is missing, once', () {
      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject(name: 'Bessey refresh');
      // The job was started before the list existed, and somebody had already
      // typed one of the companies by hand - in their own spelling.
      p.addProjectVendor(name: 'EXTRON');
      p.vendorBook.add(name: 'Extron');
      p.vendorBook.add(name: 'Shure');

      expect([for (final v in p.vendorsOffProject) v.name], ['Shure']);
      expect(p.addProjectVendorsFromBook(), 1);
      expect([for (final v in p.project.vendors) v.name], ['EXTRON', 'Shure']);

      // Pressing it again adds nothing: the company is on the job under a
      // name, and a directory that grew a second Shure every press would be
      // worse than one that never offered the first.
      expect(p.addProjectVendorsFromBook(), 0);
      expect(p.project.vendors.length, 2);
    });

    testWidgets('the Packages tab offers what the job is missing', (
      tester,
    ) async {
      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject(name: 'Bessey refresh');
      p.vendorBook.add(name: 'Extron');
      p.vendorBook.add(name: 'Shure');

      tester.view.physicalSize = const Size(1700, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: ProjectView())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('project_pane_vendors')));
      await tester.pumpAndSettle();

      // The count is what makes it worth pressing - 'add' on its own says
      // nothing about whether there is anything to add.
      final button = find.byKey(const ValueKey('add_saved_vendors'));
      expect(button, findsOneWidget);
      expect(find.text('Add saved vendors (2)'), findsOneWidget);

      // IT OPENS A LIST RATHER THAN ADDING THE LIST. A shop with nineteen
      // suppliers on the share is not asking eleven of them to quote a
      // two-room refresh.
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('vendor_pick_dialog')), findsOneWidget);
      expect(
        p.project.vendors,
        isEmpty,
        reason: 'opening the picker is not a decision',
      );

      // Nothing ticked, nothing to add.
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('vendor_pick_ok')))
            .onPressed,
        isNull,
      );

      final extron = p.vendorBook.byName('Extron')!;
      await tester.tap(find.byKey(ValueKey('vendor_pick_${extron.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('vendor_pick_ok')));
      await tester.pumpAndSettle();

      expect([for (final v in p.project.vendors) v.name], ['Extron']);
      // Still offered, because Shure is still off the job.
      expect(find.text('Add a saved vendor'), findsOneWidget);
    });

    testWidgets('the picker leaves the job alone when it is cancelled', (
      tester,
    ) async {
      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject(name: 'Bessey refresh');
      p.vendorBook.add(name: 'Extron');

      tester.view.physicalSize = const Size(1700, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: ProjectView())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('project_pane_vendors')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add_saved_vendors')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('vendor_pick_all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('vendor_pick_cancel')));
      await tester.pumpAndSettle();

      expect(p.project.vendors, isEmpty);
    });

    test('a job vendor is a copy - editing it leaves the share alone', () {
      final p = shop();
      p.newProject(name: 'Bessey refresh');
      final onJob = p.project.vendors.first;
      p.updateProjectVendor(onJob.copyWith(contact: 'someone else'));

      expect(p.project.vendors.first.contact, 'someone else');
      expect(p.vendorBook.byName('Extron')!.contact, 'quotes@example');
    });
  });
}
