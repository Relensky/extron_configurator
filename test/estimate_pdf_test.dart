import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/estimate_pdf.dart';

/// The client-facing PDF of a room estimate.
void main() {
  // Uncompressed Helvetica text is one `[(word)]TJ` per word.
  String words(List<int> bytes) => RegExp(r'\[\((.*?)\)\]TJ')
      .allMatches(latin1.decode(bytes))
      .map((m) => m.group(1)!.replaceAll(r'\(', '(').replaceAll(r'\)', ')'))
      .join(' ');

  // 1x1 PNG.
  final logo = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwAD'
    'hgGAWjR9awAAAABJRU5ErkJggg==',
  );

  CostEstimate estimate() => const CostEstimate(
    currency: r'$',
    equipment: [
      CostLine(
        key: 'a',
        description: 'Laser projector',
        model: 'EB-PU2010',
        partNumber: 'V11HA52020',
        qty: 2,
        unitPrice: 4200,
        spareQty: 1,
      ),
      CostLine(
        key: 'b',
        description: 'Network switch',
        qty: 1,
        unitPrice: 800,
        furnishedBy: 'Campus IT',
      ),
    ],
    hardware: [],
    cabling: [],
    extras: [],
    labor: [
      LaborCostLine(
        id: 'l',
        roleName: 'Installer',
        description: 'Mount and terminate',
        techs: 2,
        hours: 8,
        hourlyRate: 95,
        taxable: false,
        unrated: false,
      ),
    ],
    fees: [],
    equipmentTotal: 8400,
    hardwareTotal: 0,
    cablingTotal: 0,
    extrasTotal: 0,
    laborTotal: 1520,
    laborHours: 16,
    unratedLabor: 0,
    subtotal: 9920,
    feeTotal: 0,
    taxableBase: 8400,
    taxPercent: 7.25,
    taxLabel: 'Sales tax',
    tax: 609,
    grandTotal: 10529,
    unpricedLines: 0,
    unpricedDevices: 0,
    estimatedLines: 0,
  );

  EstimatePdfInfo info({List<int>? logoBytes}) => EstimatePdfInfo(
    roomName: 'Bessey Hall 103',
    preparedBy: 'Pat Estimator',
    preparerContact: 'pat@example.edu',
    date: DateTime(2026, 9, 17),
    logo: logoBytes == null ? null : Uint8List.fromList(logoBytes),
    scopeOfWork: 'Replace both projectors.\nRe-terminate the rack.',
    notes: 'Valid for 30 days.',
  );

  test('prints the headings, lines, totals, preparer and notes', () async {
    final bytes = await buildEstimatePdf(
      estimate(),
      info(logoBytes: logo),
      compress: false,
    );
    expect(latin1.decode(bytes), startsWith('%PDF'));
    final text = words(bytes);
    for (final expected in [
      'ESTIMATE',
      'Bessey Hall 103',
      'SCOPE OF WORK',
      'Replace both projectors.',
      'Laser projector',
      'Includes 1 spare',
      'Furnished by Campus IT',
      'By others',
      r'$8,400.00',
      'Sales tax (7.25%)',
      r'$10,529.00',
      'Pat Estimator',
      'pat@example.edu',
      'September 17, 2026',
      'NOTES',
      'Valid for 30 days.',
    ]) {
      expect(text, contains(expected), reason: 'missing "$expected"');
    }
    // The logo is embedded as an image.
    expect(latin1.decode(bytes), contains(RegExp(r'/Subtype\s*/Image')));
  });

  test('leaves out empty scope, notes and preparer', () async {
    final bytes = await buildEstimatePdf(
      estimate(),
      EstimatePdfInfo(date: DateTime(2026, 1, 2)),
      compress: false,
    );
    final text = words(bytes);
    expect(text, isNot(contains('SCOPE OF WORK')));
    expect(text, isNot(contains('NOTES')));
    expect(text, isNot(contains('PREPARED BY')));
    expect(latin1.decode(bytes), isNot(contains(RegExp(r'/Subtype\s*/Image'))));
  });

  // The footer names the ROOM, not the preparer: an estimate is read as loose
  // pages beside three others, and page 4 has to say which room it belongs to.
  test('the footer says which room the estimate is for', () async {
    final bytes = await buildEstimatePdf(
      estimate(),
      info(logoBytes: logo),
      compress: false,
    );
    final text = words(bytes);
    expect(text, contains('Estimate for Bessey Hall 103'));
    expect(text, isNot(contains('Prepared by Pat Estimator')),
        reason: 'who prepared it is on the first page, beside the date');
    expect(text, contains('Pat Estimator'),
        reason: 'and it is still printed there');
  });

  test('a room with no name leaves the footer blank', () async {
    final bytes = await buildEstimatePdf(
      estimate(),
      EstimatePdfInfo(date: DateTime(2026, 1, 2)),
      compress: false,
    );
    expect(words(bytes), isNot(contains('Estimate for')));
  });

  test('a file that is not an image is skipped rather than failing', () async {
    final bytes = await buildEstimatePdf(
      estimate(),
      info(logoBytes: utf8.encode('not a picture')),
      compress: false,
    );
    expect(latin1.decode(bytes), isNot(contains(RegExp(r'/Subtype\s*/Image'))));
  });

  test('builds with the system font when it is there', () async {
    final theme = loadEstimatePdfTheme();
    if (theme == null) return; // not a Windows machine
    final bytes = await buildEstimatePdf(
      estimate(),
      info(logoBytes: logo),
      theme: theme,
    );
    expect(latin1.decode(bytes.sublist(0, 4)), '%PDF');
    final out = Platform.environment['ESTIMATE_PDF_SAMPLE'];
    if (out != null && out.isNotEmpty) File(out).writeAsBytesSync(bytes);
  });
}
