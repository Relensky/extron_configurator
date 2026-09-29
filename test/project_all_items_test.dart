import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/online_copy.dart';
import 'package:extron_configurator/online_roundtrip.dart';
import 'package:extron_configurator/project_workbook.dart';
import 'package:extron_configurator/save_actions.dart';
import 'package:extron_configurator/xlsx_writer.dart';

/// A priority that buys only projectors, and the master sheet that links to
/// every room's tab.
void main() {
  late Directory dir;
  late AppStateProvider provider;
  late String projectFile;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('all_items_');
    provider = AppStateProvider(autoLoadSettings: false)
      ..rootFolderPath = Directory.current.path;
    await provider.loadUiSchema();
    await provider.loadKeyMap();
    await provider.loadAvDeviceLibrary();
    provider.newProject(name: 'Refresh');
    provider.addProjectManualRoomList(
      'LANG 300\t2 Projector 1 Cam 1 Mic\tCentral\t31671\n'
      '\n'
      'HOLT 171\t2 Projector\tCentral\t5000\n'
      '\n'
      'YOLO 999\tDept\t5000',
      groupsArePriorities: true,
    );
    projectFile = path.join(dir.path, 'Refresh_project.json');
    expect(await provider.saveProject(to: projectFile), isEmpty);
    final lines = provider.project.manualRooms.take(2).toList();
    final built = await buildLineItemRooms(provider, lines, dir.path);
    expect(built.built, ['LANG 300', 'HOLT 171']);
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  ProjectEstimate price() => computeProjectEstimate(
    project: provider.project,
    projectPath: projectFile,
    library: provider.avDeviceLibrary,
  );

  ProjectRoomCost room(ProjectEstimate e, String name) =>
      e.rooms.firstWhere((r) => r.name == name);

  group('a priority that buys only projectors', () {
    test('only the projectors are on the job; the rest stays as existing',
        () {
      final full = room(price(), 'HOLT 171').estimate!;
      provider.setPriorityBuysOnly(2, ['Projector']);
      final holt = room(price(), 'HOLT 171').estimate!;

      expect(holt.equipment, isNotEmpty);
      expect(holt.equipment.every((l) => l.category == 'Projector'), isTrue);
      expect(holt.equipment.every((l) => l.total > 0), isTrue);
      expect(holt.hardware, isEmpty);
      expect(holt.cabling, isEmpty);
      expect(holt.extras, isEmpty);
      // Counted and said, not silently dropped.
      expect(holt.excludedLines, greaterThan(0));
      expect(
        holt.excludedLines,
        full.equipment.length +
            full.hardware.length +
            full.cabling.length +
            full.extras.length -
            holt.equipment.length,
      );
    });

    test('the room on its own still lists everything', () {
      provider.setPriorityBuysOnly(2, ['Projector']);
      final loaded = readRoomFromDisk(
        path.join(dir.path, 'HOLT_171_config.json'),
      );
      final own = computeRoomCost(
        model: loaded.model,
        library: provider.avDeviceLibrary,
        settings: loaded.settings,
      );
      expect(own.equipment.any((l) => l.category != 'Projector'), isTrue);
    });

    test('rooms at other priorities buy everything', () {
      final before = room(price(), 'LANG 300').total;
      provider.setPriorityBuysOnly(2, ['Projector']);
      expect(room(price(), 'LANG 300').total, before);
    });

    test('the room file itself is not changed', () {
      final cost = File(path.join(dir.path, 'HOLT_171_config_cost.json'));
      final before = cost.readAsStringSync();
      provider.setPriorityBuysOnly(2, ['Projector']);
      price();
      expect(cost.readAsStringSync(), before);
    });

    test('it can name items as well as categories', () {
      provider.setPriorityBuysOnly(2, ['PT-VMZ62BU8', 'ShareLink Pro 2000']);
      final holt = room(price(), 'HOLT 171').estimate!;
      expect(
        holt.equipment.map((l) => l.model).toSet(),
        {'PT-VMZ62BU8', 'ShareLink Pro 2000'},
      );
    });

    test('add-ons are quoted for each room at the priority', () {
      provider.setPriorityBuysOnly(2, ['Projector']);
      provider.setPriorityAddOns(2, [
        (model: 'Speakers', description: 'Ceiling speakers', qty: 2),
      ]);
      final holt = room(price(), 'HOLT 171').estimate!;
      final speakers = holt.equipment.where((l) => l.model == 'Speakers');
      expect(speakers, hasLength(1), reason: 'kept despite projectors only');
      expect(speakers.single.qty, 2);
      expect(speakers.single.description, 'Ceiling speakers');
      // Not the other priorities' rooms.
      expect(
        room(price(), 'LANG 300').estimate!.equipment.any(
          (l) => l.description == 'Ceiling speakers',
        ),
        isFalse,
      );
      // On the project only.
      final flow = File(path.join(dir.path, 'HOLT_171_config_cost.json'))
          .readAsStringSync();
      expect(flow, isNot(contains('Ceiling speakers')));
      // And kept with the job.
      final back = BuildingProject.fromJson(provider.project.toJson());
      expect(back.addOnsFor(2).single.qty, 2);
      expect(back.addOnsFor(2).single.model, 'Speakers');
      provider.setPriorityAddOns(2, []);
      expect(
        room(price(), 'HOLT 171').estimate!.equipment.any(
          (l) => l.model == 'Speakers',
        ),
        isFalse,
      );
    });

    test('it is saved with the project', () {
      provider.setPriorityBuysOnly(2, ['Projector']);
      final back = BuildingProject.fromJson(provider.project.toJson());
      expect(back.buysOnlyFor(2), ['Projector']);
      expect(back.buysOnlyFor(1), isEmpty);
    });

    test('clearing it buys everything again', () {
      final full = room(price(), 'HOLT 171').total;
      provider.setPriorityBuysOnly(2, ['Projector']);
      expect(room(price(), 'HOLT 171').total, lessThan(full));
      provider.setPriorityBuysOnly(2, []);
      expect(room(price(), 'HOLT 171').total, full);
    });
  });

  group('the all-items sheet', () {
    test('lists every line with its room linked to that room\'s tab', () {
      provider.setPriorityBuysOnly(2, ['Projector']);
      final estimate = price();
      final sections = allItemsSections(
        estimate,
        roomTabs: {for (final r in estimate.rooms) r.ref.id: r.name},
      );
      final items = sections.first.rows;
      final holtRows = items
          .where((r) => r[1] is XlsxLink && r[1].text == 'HOLT 171');
      expect(holtRows, isNotEmpty);
      expect((holtRows.first[1] as XlsxLink).sheet, 'HOLT 171');
      // Only what the priority replaces is on the master list.
      expect(holtRows.every((r) => r[3] == 'Equipment'), isTrue);
      expect(holtRows.map((r) => r[4]).toSet(), {'PT-VMZ62BU8'});

      final totals = sections.last.rows;
      expect(totals.any((r) => '${r.first}'.startsWith('YOLO 999')), isTrue);
      expect(totals.last.first, 'Total');
    });

    test('the workbook links the master to each tab and back', () {
      final bytes = buildProjectWorkbookBytes(estimate: price());
      final archive = ZipDecoder().decodeBytes(bytes);
      String file(String name) =>
          utf8.decode(archive.findFile(name)!.content as List<int>);

      final book = file('xl/workbook.xml');
      final names = RegExp(r'<sheet name="([^"]+)"')
          .allMatches(book)
          .map((m) => m.group(1))
          .toList();
      expect(names.take(2), ['Summary', kProjectAllItemsSheet]);
      expect(names, containsAll(['LANG 300', 'HOLT 171']));

      final master = file('xl/worksheets/sheet2.xml');
      expect(master, contains('<hyperlinks>'));
      expect(master, contains("location=\"'HOLT 171'!A1\""));
      // The items stay in the grid rather than lifted onto lines of their own.
      expect(master, isNot(contains('Item:  ')));

      final holt = file('xl/worksheets/sheet${names.indexOf('HOLT 171') + 1}'
          '.xml');
      expect(
        holt,
        contains("location=\"'$kProjectAllItemsSheet'!A1\""),
      );
    });
  });

  group('prices read from the master list', () {
    test('every room line points at its part on Core Components', () {
      final bytes = buildProjectWorkbookBytes(estimate: price());
      final archive = ZipDecoder().decodeBytes(bytes);
      String file(String name) =>
          utf8.decode(archive.findFile(name)!.content as List<int>);
      final names = RegExp(r'<sheet name="([^"]+)"')
          .allMatches(file('xl/workbook.xml'))
          .map((m) => m.group(1)!)
          .toList();
      String sheet(String name) =>
          file('xl/worksheets/sheet${names.indexOf(name) + 1}.xml');

      // The master's own cells, by reference.
      final master = sheet('Core Components');
      final values = {
        for (final m in RegExp(r'<c r="([A-Z]+\d+)"[^>]*>(?:<f>[^<]*</f>)?<v>([^<]*)</v>')
            .allMatches(master))
          m.group(1)!: double.tryParse(m.group(2)!),
      };
      // Its Extended is its own Qty times its own Unit price.
      expect(master, matches(RegExp(r'<f>[A-Z]+\d+\*[A-Z]+\d+</f>')));

      var linked = 0;
      for (final room in ['LANG 300', 'HOLT 171', kProjectAllItemsSheet]) {
        final xml = sheet(room);
        final unitRefs = RegExp(
          r"<f>&apos;Core Components&apos;!([A-Z]+\d+)</f><v>([^<]*)</v>|"
          r"<f>'Core Components'!([A-Z]+\d+)</f><v>([^<]*)</v>",
        ).allMatches(xml);
        for (final m in unitRefs) {
          final ref = m.group(1) ?? m.group(3)!;
          final cached = double.parse(m.group(2) ?? m.group(4)!);
          expect(values[ref], cached, reason: '$room reads $ref');
          linked++;
        }
      }
      expect(linked, greaterThan(10));
    });
  });

  group('the workbook adds itself up', () {
    (int, int) checkBook(List<int> bytes) {
      final archive = ZipDecoder().decodeBytes(bytes);
      String file(String name) =>
          utf8.decode(archive.findFile(name)!.content as List<int>);
      final names = RegExp(r'<sheet name="([^"]+)"')
          .allMatches(file('xl/workbook.xml'))
          .map((m) => m.group(1)!.replaceAll('&apos;', "'"))
          .toList();

      String unescape(String v) => v
          .replaceAll('&quot;', '"')
          .replaceAll('&apos;', "'")
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&amp;', '&');

      // sheet -> cell -> (formula, cached)
      final book = <String, Map<String, (String?, String)>>{};
      for (var i = 0; i < names.length; i++) {
        final xml = file('xl/worksheets/sheet${i + 1}.xml');
        final cells = <String, (String?, String)>{};
        for (final m in RegExp(
          r'<c r="([A-Z]+\d+)"[^>]*?(?:/>|>(.*?)</c>)',
        ).allMatches(xml)) {
          final body = m.group(2) ?? '';
          final f = RegExp(r'<f>(.*?)</f>').firstMatch(body)?.group(1);
          final v = RegExp(r'<v>(.*?)</v>').firstMatch(body)?.group(1) ??
              RegExp(r'<t[^>]*>(.*?)</t>').firstMatch(body)?.group(1) ??
              '';
          cells[m.group(1)!] = (f == null ? null : unescape(f), unescape(v));
        }
        book[names[i]] = cells;
      }

      int col(String letters) =>
          letters.codeUnits.fold(0, (a, c) => a * 26 + (c - 64));
      String letter(int n) {
        var s = '';
        while (n > 0) {
          s = String.fromCharCode(65 + (n - 1) % 26) + s;
          n = (n - 1) ~/ 26;
        }
        return s;
      }

      late Object Function(String sheet, String ref) valueOf;

      Object evaluate(String sheet, String f) {
        var i = 0;
        void skip() {
          while (i < f.length && f[i] == ' ') {
            i++;
          }
        }

        late Object Function() expr;
        (String, String) readRef() {
          var target = sheet;
          if (f[i] == "'") {
            final end = f.indexOf("'!", i + 1);
            target = f.substring(i + 1, end).replaceAll("''", "'");
            i = end + 2;
          }
          final m = RegExp(r'[A-Z]+\d+').matchAsPrefix(f, i)!;
          i = m.end;
          return (target, m.group(0)!);
        }

        Object atom() {
          skip();
          if (f.startsWith('SUM(', i) || f.startsWith('ROUND(', i)) {
            final round = f.startsWith('ROUND(', i);
            i += round ? 6 : 4;
            if (round) {
              final v = expr() as double;
              i++; // ,
              final d = int.parse(RegExp(r'\d+').matchAsPrefix(f, i)!.group(0)!);
              i += '$d'.length + 1;
              final p = 1.0 * [1, 10, 100, 1000][d];
              return (v * p).round() / p;
            }
            final (sh, a) = readRef();
            i++; // :
            final (_, b) = readRef();
            i++; // )
            final c = col(RegExp(r'[A-Z]+').firstMatch(a)!.group(0)!);
            final r1 = int.parse(RegExp(r'\d+').firstMatch(a)!.group(0)!);
            final r2 = int.parse(RegExp(r'\d+').firstMatch(b)!.group(0)!);
            var sum = 0.0;
            for (var r = r1; r <= r2; r++) {
              final v = valueOf(sh, '${letter(c)}$r');
              if (v is double) sum += v;
            }
            return sum;
          }
          if (f[i] == '"') {
            final end = f.indexOf('"', i + 1);
            final t = f.substring(i + 1, end);
            i = end + 1;
            return t;
          }
          final num = RegExp(r'\d+(\.\d+)?').matchAsPrefix(f, i);
          if (num != null && !RegExp(r'[A-Z]').hasMatch(f[i])) {
            i = num.end;
            return double.parse(num.group(0)!);
          }
          final (sh, ref) = readRef();
          return valueOf(sh, ref);
        }

        Object term() {
          var v = atom();
          skip();
          while (i < f.length && (f[i] == '*' || f[i] == '/')) {
            final op = f[i++];
            final w = atom() as double;
            v = op == '*' ? (v as double) * w : (v as double) / w;
            skip();
          }
          return v;
        }

        expr = () {
          var v = term();
          skip();
          while (i < f.length && '+-&'.contains(f[i])) {
            final op = f[i++];
            final w = term();
            if (op == '&') {
              v = '${v is double ? '' : v}$w';
            } else {
              final a = v is double ? v : 0.0;
              final b = w is double ? w : 0.0;
              v = op == '+' ? a + b : a - b;
            }
            skip();
          }
          return v;
        };
        return expr();
      }

      final memo = <String, Object>{};
      valueOf = (sheet, ref) {
        final key = '$sheet!$ref';
        final hit = memo[key];
        if (hit != null) return hit;
        final cell = book[sheet]?[ref];
        if (cell == null) return '';
        final (f, v) = cell;
        final out = f == null
            ? (double.tryParse(v) ?? v)
            : evaluate(sheet, f);
        return memo[key] = out;
      };

      var formulas = 0;
      var totals = 0;
      book.forEach((sheet, cells) {
        cells.forEach((ref, cell) {
          final (f, cached) = cell;
          if (f == null) return;
          formulas++;
          if (f.contains('SUM(') || f.contains('ROUND(')) totals++;
          final got = valueOf(sheet, ref);
          final want = double.tryParse(cached);
          if (want != null && got is double) {
            expect(got, closeTo(want, 0.011), reason: '$sheet!$ref = $f');
          } else {
            expect('$got', cached, reason: '$sheet!$ref = $f');
          }
        });
      });
      return (formulas, totals);
    }


    test('every formula comes to the figure it shows', () {
      final (formulas, totals) =
          checkBook(buildProjectWorkbookBytes(estimate: price()));
      expect(formulas, greaterThan(40));
      expect(totals, greaterThanOrEqualTo(5));

      // The Summary reads the room tabs, and its building total adds them.
      final archive = ZipDecoder().decodeBytes(
        buildProjectWorkbookBytes(estimate: price()),
      );
      final summary = utf8.decode(
        archive.findFile('xl/worksheets/sheet1.xml')!.content as List<int>,
      );
      expect(
        RegExp(r"<f>(&apos;|')(LANG 300|HOLT 171)(&apos;|')!").allMatches(summary).length,
        greaterThanOrEqualTo(4),
      );
      expect(summary, contains('<f>'));
    });

    test('fees and tax follow the lines too', () {
      final costFile = File(path.join(dir.path, 'HOLT_171_config_cost.json'));
      final doc = jsonDecode(costFile.readAsStringSync()) as Map<String, dynamic>;
      final cost = Map<String, dynamic>.from(doc['cost'] as Map)
        ..['fees'] = [
          {'id': 'f1', 'name': 'Contingency', 'percent': 10, 'taxable': true},
          {'id': 'f2', 'name': 'Freight', 'percent': 2.5, 'taxable': false},
        ]
        ..['taxPercent'] = 7.25
        // Two crews, so the Summary's hours have something to add up.
        ..['labor'] = [
          {'id': 'l1', 'customRate': 95, 'techs': 2, 'hours': 6, 'taxable': false},
          {'id': 'l2', 'customRate': 120, 'techs': 1, 'hours': 3.5, 'taxable': true},
        ];
      doc['cost'] = cost;
      costFile.writeAsStringSync(jsonEncode(doc));
      final estimate = price();
      final holt = room(estimate, 'HOLT 171').estimate!;
      expect(holt.fees, hasLength(2));
      expect(holt.tax, greaterThan(0));
      expect(holt.laborCrewHours, 9.5);
      expect(holt.laborHours, 15.5);

      final bytes = buildProjectWorkbookBytes(estimate: estimate);
      final (_, totals) = checkBook(bytes);
      // Two fees and the tax, on top of the sums.
      expect(totals, greaterThanOrEqualTo(8));

      // The Summary's crew hours and total hours add up HOLT 171's labor.
      final summary = utf8.decode(
        ZipDecoder()
            .decodeBytes(bytes)
            .findFile('xl/worksheets/sheet1.xml')!
            .content as List<int>,
      );
      RegExp hoursFormula(String value) => RegExp(
        r"<f>SUM\((&apos;|')HOLT 171(&apos;|')![A-Z]+\d+:[A-Z]+\d+\)</f>"
        '<v>$value</v>',
      );
      expect(summary, matches(hoursFormula(r'9\.5')));
      expect(summary, matches(hoursFormula(r'15\.5')));
    });

    test('names, models and part numbers read from the master list', () {
      final archive = ZipDecoder().decodeBytes(
        buildProjectWorkbookBytes(estimate: price()),
      );
      final xml = archive.files
          .where((f) => f.name.startsWith('xl/worksheets/'))
          .map((f) => utf8.decode(f.content as List<int>))
          .join();
      expect(
        RegExp(r'<f>&apos;Core Components&apos;![A-Z]+\d+&amp;&quot;&quot;</f>|'
                r"<f>'Core Components'![A-Z]+\d+&amp;&quot;&quot;</f>")
            .allMatches(xml)
            .length,
        greaterThan(20),
      );
    });
  });

  group('Core Components read back', () {
    /// The workbook with one row of Core Components edited the way somebody
    /// would in Excel: [cells] maps a column letter to what it now says.
    List<int> edited(List<int> bytes, String rowId, Map<String, String> cells) {
      final archive = ZipDecoder().decodeBytes(bytes);
      final names = RegExp(r'<sheet name="([^"]+)"')
          .allMatches(utf8.decode(
              archive.findFile('xl/workbook.xml')!.content as List<int>))
          .map((m) => m.group(1))
          .toList();
      final sheetFile =
          'xl/worksheets/sheet${names.indexOf('Core Components') + 1}.xml';
      var xml = utf8.decode(archive.findFile(sheetFile)!.content as List<int>);
      final row = RegExp(
        r'<row r="(\d+)"[^>]*>((?:(?!</row>).)*' +
            rowId +
            r'(?:(?!</row>).)*)</row>',
      ).firstMatch(xml)!;
      final r = row.group(1)!;
      var body = row.group(2)!;
      cells.forEach((col, value) {
        final cell = RegExp('<c r="$col$r"[^>]*?(/>|>.*?</c>)').firstMatch(body)!;
        final number = double.tryParse(value) != null;
        body = body.replaceFirst(
          cell.group(0)!,
          number
              ? '<c r="$col$r"><v>$value</v></c>'
              : '<c r="$col$r" t="inlineStr"><is><t>$value</t></is></c>',
        );
      });
      xml = xml.replaceFirst(row.group(0)!, row.group(0)!.replaceFirst(row.group(2)!, body));
      final out = Archive();
      for (final f in archive.files) {
        if (f.name == sheetFile) {
          out.addFile(ArchiveFile.string(f.name, xml));
        } else {
          out.addFile(ArchiveFile(f.name, f.size, f.content));
        }
      }
      return ZipEncoder().encodeBytes(out);
    }

    test('a price and a name edited there come back into every room', () async {
      final estimate = price();
      final projector = estimate.master
          .firstWhere((l) => l.model == 'PT-VMZ62BU8');
      final bytes = buildProjectWorkbookBytes(estimate: estimate);
      // Column A is the part, H the unit price - read off the header.
      final changed = edited(bytes, masterRowId(projector.key), {
        'A': 'Laser projector',
        'H': '3500',
      });

      final review = provider.reviewOnlineImport(
        Uint8List.fromList(changed),
      );
      expect(review.read.wrongFile, isFalse);
      expect(review.read.master, hasLength(1));
      final edit = review.read.master.single;
      expect(edit.name, 'Laser projector');
      expect(edit.unitPrice, 3500);
      expect(review.changes.map((c) => c.kind), contains('part'));

      final offers = provider.catalogOffersFor(review.read.master);
      expect(offers.map((o) => o.kind), [CatalogOfferKind.price]);

      expect(await provider.applyMasterEdits(review.read.master), 1);

      // The room open in the editor takes it in memory, to be saved with it.
      expect(provider.currentConfigPath, endsWith('HOLT_171_config.json'));
      expect(provider.avCost.priceOverrides.values, contains(3500));
      expect(
        provider.avNodes
            .where((n) => n.model == 'PT-VMZ62BU8')
            .map((n) => n.label)
            .toSet(),
        {'Laser projector'},
      );
      // A closed room takes it on disk: the price and the name.
      for (final room in ['LANG_300']) {
        final cost = jsonDecode(
          File(path.join(dir.path, '${room}_config_cost.json'))
              .readAsStringSync(),
        );
        expect(
          (cost['cost']['priceOverrides'] as Map).values,
          contains(3500),
          reason: room,
        );
        final flow = jsonDecode(
          File(path.join(dir.path, '${room}_config_av_flow.json'))
              .readAsStringSync(),
        );
        expect(
          (flow['nodes'] as List)
              .where((n) => n['model'] == 'PT-VMZ62BU8')
              .map((n) => n['label'])
              .toSet(),
          {'Laser projector'},
          reason: room,
        );
      }
      // And the job prices from it.
      final after = price().master.firstWhere((l) => l.model == 'PT-VMZ62BU8');
      expect(after.unitPrice, 3500);
      expect(after.description, 'Laser projector');

      // Pulling the same workbook again changes nothing more.
      final again = provider.reviewOnlineImport(Uint8List.fromList(
        edited(
          buildProjectWorkbookBytes(estimate: price()),
          masterRowId(after.key),
          const {},
        ),
      ));
      expect(again.read.master, isEmpty);
    });

    test('a save does not publish over an edited Core Components', () async {
      final folder = Directory(path.join(dir.path, 'online'))..createSync();
      provider.setProjectOnlineFolder(folder.path);
      provider.setProjectOnlineAutoPublish(true);
      expect(await provider.saveProject(), '');
      final file = File(path.join(folder.path, onlineWorkbookName(provider.project)));
      expect(file.existsSync(), isTrue);

      // Somebody changes a price in the published copy.
      final projector = price().master
          .firstWhere((l) => l.model == 'PT-VMZ62BU8');
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      file.writeAsBytesSync(edited(
        file.readAsBytesSync(),
        masterRowId(projector.key),
        {'H': '3500'},
      ));
      final theirs = file.readAsBytesSync();

      provider.setProjectField(stakeholder: 'Facilities');
      expect(await provider.saveProject(), '');
      final hold = provider.onlineHold;
      expect(hold, isNotNull, reason: 'their price was found');
      expect(hold!.changes.map((c) => c.kind), contains('part'));
      expect(file.readAsBytesSync(), theirs, reason: 'left as they wrote it');
    });

    test('the catalog is updated only when asked', () async {
      final catalogFile = File(path.join(dir.path, 'av_devices.json'));
      provider.avDevicesFilePath = catalogFile.path;
      final projector = price().master
          .firstWhere((l) => l.model == 'PT-VMZ62BU8');
      final was = provider.avDeviceLibrary
          .templateForModel('PT-VMZ62BU8')!
          .price;

      final edits = [
        (
          key: projector.key,
          label: projector.description,
          name: null,
          model: null,
          partNumber: 'PT-VMZ62BU8-X',
          unitPrice: 3500.0,
        ),
      ];
      final offers = provider.catalogOffersFor(edits);
      expect(offers.map((o) => o.kind).toSet(),
          {CatalogOfferKind.price, CatalogOfferKind.partNumber});

      // Just this job: the catalog keeps its price.
      await provider.applyMasterEdits(edits);
      expect(provider.avDeviceLibrary.templateForModel('PT-VMZ62BU8')!.price,
          was);

      // Asked: it takes both.
      expect(await provider.applyCatalogOffers(offers), isEmpty);
      final t = provider.avDeviceLibrary.templateForModel('PT-VMZ62BU8')!;
      expect(t.price, 3500);
      expect(t.partNumber, 'PT-VMZ62BU8-X');
      expect(catalogFile.existsSync(), isTrue);
    });
  });
}
