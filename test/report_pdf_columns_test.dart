import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/report_pdf.dart';
import 'package:extron_configurator/report_tools.dart';

/// A quote request table with a long Rooms column still lays out: the other
/// columns keep their widths and the rooms wrap.
void main() {
  test('a long rooms column wraps instead of squeezing the rest', () async {
    final rooms = [
      for (var i = 101; i < 140; i++) 'ARTS $i x1',
    ].join(', ');
    final ReportSection items = (
      title: 'Items',
      header: const [
        'Model',
        'Manufacturer',
        'Part number',
        'Qty',
        'Our estimate (unit)',
        'Our estimate (ext)',
        'Rooms',
      ],
      rows: [
        for (var i = 0; i < 6; i++)
          ['DTP CrossPoint 84 4K', 'Extron', '60-1381-01', 39, 1234.0, 48126.0,
              rooms],
      ],
    );
    final bytes = await buildReportSectionsPdf(
      title: 'Job - quote request',
      sections: [items],
      generated: DateTime(2026, 11, 19),
    );
    expect(bytes.length, greaterThan(1000));
    // A copy to look at, when asked for.
    final out = Platform.environment['RCB_PDF_OUT'];
    if (out != null && out.isNotEmpty) File(out).writeAsBytesSync(bytes);
  });
}
